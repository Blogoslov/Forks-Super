#
# Forks::Super::Job - object representing a task to perform in 
#                     a background process
#

package Forks::Super::Job;
use Forks::Super::Debug qw(debug);
use Forks::Super::Util qw(is_number qualify_sub_name);
use Forks::Super::Config qw(:all);
use Forks::Super::Queue qw(queue_job);
use Forks::Super::Job::OS;
use Forks::Super::Job::Timeout;
use Forks::Super::Job::Callback qw(run_callback);
use Forks::Super::Job::Ipc;
use Exporter;
use base 'Exporter';
use Carp;
use IO::Handle;
use warnings;

our (@ALL_JOBS, %ALL_JOBS);
our @EXPORT = qw(@ALL_JOBS %ALL_JOBS);

sub new {
  my ($class, $opts) = @_;
  my $this = {};
  if (ref $opts eq 'HASH') {
    $this->{$_} = $opts->{$_} foreach keys %$opts;
  }
  $this->{created} = Forks::Super::Util::Time();
  $this->{state} = 'NEW';
  $this->{ppid} = $$;
  push @ALL_JOBS, $this;
  return bless $this, 'Forks::Super::Job';
}

sub is_complete {
  my $job = shift;
  return defined $job->{state} &&
    ($job->{state} eq 'COMPLETE' || $job->{state} eq 'REAPED');
}

sub is_started {
  my $job = shift;
  return $job->is_complete ||
    $job->{state} eq 'ACTIVE' ||
      $job->{state} eq 'SUSPENDED';
}

sub mark_complete {
  my $job = shift;
  $job->{state} = 'COMPLETE';
  $job->{end} = Forks::Super::Util::Time();

  $job->run_callback("collect");
  $job->run_callback("finish");
}

sub mark_reaped {
  my $job = shift;
  $job->{state} = 'REAPED';
  $job->{reaped} = Forks::Super::Util::Time();
  $? = $job->{status};
  debug("Job $job->{pid} reaped") if $job->{debug};
  return;
}

#
# determine whether a job is eligible to start
#
sub can_launch {
  no strict 'refs';

  my $job = shift;
  $job->{last_check} = Forks::Super::Util::Time();
  if (defined $job->{can_launch}) {
    if (ref $job->{can_launch} eq 'CODE') {
      return $job->{can_launch}->($job);
    } elsif (ref $job->{can_launch} eq '') {
      #no strict 'refs';
      my $can_launch_sub = $job->{can_launch};
      return $can_launch_sub->($job);
    }
  } else {
    return $job->_can_launch;
  }
}

sub _can_launch_delayed_start_check {
  my $job = shift;
  return 1 if !defined $job->{start_after} || 
    Forks::Super::Util::Time() >= $job->{start_after};

  debug('Forks::Super::Job::_can_launch(): ',
	'start delay requested. launch fail') if $job->{debug};

  # delay option should normally be associated with queue on busy behavior.
  # any reason not to make this the default ?
  #  delay + fail   is pretty dumb
  #  delay + block  is like sleep + fork 

  $job->{_on_busy} = 'QUEUE' if not defined $job->{on_busy};
  #$job->{_on_busy} = 'QUEUE' if not defined $job->{_on_busy};
  return 0;
}

sub _can_launch_dependency_check {
  my $job = shift;
  my @dep_on = defined $job->{depend_on} ? @{$job->{depend_on}} : ();
  my @dep_start = defined $job->{depend_start} ? @{$job->{depend_start}} : ();

  foreach my $dj (@dep_on) {
    my $j = $ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Forks::Super::Job: ",
	"dependency $dj for job $job->{pid} is invalid. Ignoring.\n";
      next;
    }
    unless ($j->is_complete) {
      debug('Forks::Super::Job::_can_launch(): ',
	"job waiting for job $j->{pid} to finish. launch fail.")
	if $j->{debug};
      return 0;
    }
  }

  foreach my $dj (@dep_start) {
    my $j = $ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Forks::Super::Job ",
	"start dependency $dj for job $job->{pid} is invalid. Ignoring.\n";
      next;
    }
    unless ($j->is_started) {
      debug('Forks::Super::Job::_can_launch(): ',
	"job waiting for job $j->{pid} to start. launch fail.")
	if $j->{debug};
      return 0;
    }
  }
  return 1;
}

#
# count the number of active processes
#
sub count_active_processes {
  my $optional_pgid = shift;
  if (defined $optional_pgid) {
    return scalar grep {
      $_->{state} eq 'ACTIVE'
	and $_->{pgid} == $optional_pgid } @ALL_JOBS;
  }
  return scalar grep { defined $_->{state} 
			 && $_->{state} eq 'ACTIVE' } @ALL_JOBS;
}

#
# get the current CPU load. May not be possible
# to do on all operating systems.
#
sub get_cpu_load {
  # check CONFIG about how to get_cpu_load
  # not implemented
  return 0.0;
}



#
# default function for determining whether the system
# is too busy to create a new child process or not
#
sub _can_launch {
  # no warnings qw(once);

  # XXX - need better handling of case  $max_proc = "0"

  my $job = shift;
  my $max_proc = defined $job->{max_proc}
    ? $job->{max_proc} : $Forks::Super::MAX_PROC || 0;
  my $max_load = defined $job->{max_load}
    ? $job->{max_load} : $Forks::Super::MAX_LOAD;
  my $force = defined $job->{max_load} && $job->{force};

  if ($force) {
    debug('Forks::Super::Job::_can_launch(): force attr set. launch ok')
      if $job->{debug};
    return 1;
  }

  return 0 if not $job->_can_launch_delayed_start_check;
  return 0 if not $job->_can_launch_dependency_check;

  if ($max_proc > 0) {
    my $num_active = count_active_processes();
    if ($num_active >= $max_proc) {
      debug('Forks::Super::Job::_can_launch(): ',
	"active jobs $num_active exceeds limit $max_proc. ",
	    'launch fail.') if $job->{debug};
      return 0;
    }
  }

  if (0 && $max_load > 0) {  # feature disabled
    my $load = get_cpu_load();
    if ($load > $max_load) {
      debug('Forks::Super::Job::_can_launch(): ',
	"cpu load $load exceeds limit $max_load. launch fail.")
	if $job->{debug};
      return 0;
    }
  }

  debug('Forks::Super::Job::_can_launch(): system not busy. launch ok.')
    if $job->{debug};
  return 1;
}

#
# make a system fork call and configure the job object
# in the parent and the child processes
#
sub launch {
  my $job = shift;
  if ($job->is_started) {
    Carp::confess "Forks::Super::Job::launch() ",
	"called on a job in state $job->{state}!\n";
  }

  if ($$ != $Forks::Super::MAIN_PID && $Forks::Super::CHILD_FORK_OK < 1) {
    return _launch_from_child($job);
  }
  $job->preconfig_fh;
  $job->preconfig2;





  my $retries = $job->{retries} || 1;


  my $pid = CORE::fork();
  while (!defined $pid && --$retries > 0) {
    warn "Forks::Super::launch: ",
      "system fork call returned undef. Retrying ...\n";
    pause(1 + ($job->{retries} || 1) - $retries);
  }







  if (!defined $pid) {
    debug('Forks::Super::Job::launch(): CORE::fork() returned undefined!')
      if $job->{debug};
    return;
  }


  if (Forks::Super::Util::isValidPid($pid)) { # parent
    $ALL_JOBS{$pid} = $job;
    if (defined $job->{state} && 
	$job->{state} ne 'NEW' &&
	$job->{state} ne 'LAUNCHING' &&
	$job->{state} ne 'DEFERRED') {
      warn "Forks::Super::Job::launch(): ",
	"job $pid already has state: $job->{state}\n";
    } else {
      $job->{state} = 'ACTIVE';

      #
      # it is possible that this child exited quickly and has already
      # been reaped in the SIGCHLD handler. In that case, the signal
      # handler should have made an entry in %Forks::Super::BASTARD_DATA
      # for this process.
      #
      if (defined $Forks::Super::BASTARD_DATA{$pid}) {
	warn "Forks::Super::Job::launch: ",
	  "Job $pid reaped before parent initialization.\n";
	$job->mark_complete;
	($job->{end}, $job->{status})
	  = @{delete $Forks::Super::BASTARD_DATA{$pid}};
      }
    }
    $job->{real_pid} = $pid;
    $job->{pid} = $pid unless defined $job->{pid};
    $job->{start} = Forks::Super::Util::Time();

    $job->config_parent;
    $job->run_callback("start");
    return $pid;
  } elsif ($pid != 0) {
    Carp::confess "Forks::Super::launch(): ",
	"Somehow we got pid=$pid from fork call.";
  }

  # child
  Forks::Super::init_child() if defined &Forks::Super::init_child;
  $job->config_child;
  if ($job->{style} eq 'cmd') {
    local $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
    local $ENV{_FORK_PID} = $$ if $^O eq "MSWin32";
    debug("Executing [ @{$job->{cmd}} ]") if $job->{debug};
    my $c1 = system( @{$job->{cmd}} );
    debug("Exit code of $job->{pid} was $c1") if $job->{debug};
    exit $c1 >> 8;
  } elsif ($job->{style} eq 'exec') {
    local $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
    local $ENV{_FORK_PID} = $$ if $^O eq "MSWin32";
    debug("Exec'ing [ @{$job->{exec}} ]") if $job->{debug};
    exec( @{$job->{exec}} );
  } elsif ($job->{style} eq 'sub') {
    no strict 'refs';
    $job->{sub}->(@{$job->{args}});
    debug("Job $$ subroutine call has completed") if $job->{debug};
    exit 0;
  }
  return 0;
}

sub _launch_from_child {
  my $job = shift;
  if ($Forks::Super::CHILD_FORK_OK == 0) {
    carp 'Forks::Super::Job::launch(): fork() not allowed ',
      "in child process $$ while \$Forks::Super::CHILD_FORK_OK ",
	"is not set!\n";

    return;
  } elsif ($Forks::Super::CHILD_FORK_OK == -1) {
    carp "Forks::Super::Job::launch(): Forks::Super::fork() ",
      "call not allowed\n",
	"in child process $$ while \$Forks::Super::CHILD_FORK_OK <= 0.\n",
	  "Will create child of child with CORE::fork()\n";

    my $pid = CORE::fork();
    if (defined $pid && $pid == 0) {
      # child of child
      if (defined &Forks::Super::init_child) {
	Forks::Super::init_child();
      } else {
	init_child();
      }
      return $pid;
    }
    return $pid;
  }
  return;
}

# returns a Forks::Super::Job object with the given identifier
sub get {
  my $id = shift;
  if (!defined $id) {
    Carp::cluck "undef value passed to Forks::Super::Job::get()";
  }
  if (defined $ALL_JOBS{$id}) {
    return $ALL_JOBS{$id};
  }
  return getByPid($id) || getByName($id);
}

sub getByPid {
  my $id = shift;
  if (is_number($id)) {
    my @j = grep { (defined $_->{pid} && $_->{pid} == $id) ||
		   (defined $_->{real_pid} && $_->{real_pid} == $id) 
		 } @ALL_JOBS;
    return $j[0] if @j > 0;
  }
  return;
}

sub getByName {
  my $id = shift;
  my @j = grep { defined $_->{name} && $_->{name} eq $id } @ALL_JOBS;
  if (@j > 0) {
    return wantarray ? @j : $j[0];
  }
  return;
}

#
# do further initialization of a Forks::Super::Job object,
# mainly setting derived fields
#
sub preconfig {
  my $job = shift;

  $job->preconfig_style;
  $job->preconfig_busy_action;
  $job->preconfig_start_time;
  $job->preconfig_dependencies;
  Forks::Super::Job::Callback::preconfig_callbacks($job);
  return;
}

# some final initialization just before launch
sub preconfig2 {
  my $job = shift;
  if (!defined $job->{debug}) {
    $job->{debug} = $Forks::Super::Debug::DEBUG;
  }
}

sub preconfig_style {
  my $job = shift;

  ###################
  # set up style.
  #
  if (defined $job->{cmd}) {
    if (ref $job->{cmd} eq '') {
      $job->{cmd} = [ $job->{cmd} ];
    }
    $job->{style} = "cmd";
  } elsif (defined $job->{exec}) {
    if (ref $job->{exec} eq '') {
      $job->{exec} = [ $job->{exec} ];
    }
    $job->{style} = "exec";
  } elsif (defined $job->{sub}) {
    $job->{style} = "sub";
    $job->{sub} = qualify_sub_name $job->{sub};
    if (defined $job->{args}) {
      if (ref $job->{args} eq '') {
	$job->{args} = [ $job->{args} ];
      }
    } else {
      $job->{args} = [];
    }
  } else {
    $job->{style} = "natural";
  }
  return;
}

sub preconfig_busy_action {
  my $job = shift;

  ######################
  # what will we do if the job cannot launch?
  #
  if (defined $job->{on_busy}) {
    $job->{_on_busy} = $job->{on_busy};
  } else {
    $job->{_on_busy} = $Forks::Super::ON_BUSY || 'block';
  }
  $job->{_on_busy} = uc $job->{_on_busy};

  ########################
  # make a queue priority available if needed
  #
  if (not defined $job->{queue_priority}) {
    $job->{queue_priority} = Forks::Super::Queue::get_default_priority();
  }
  return;
}

sub preconfig_start_time {
  my $job = shift;

  ###########################
  # configure a future start time
  if (defined $job->{delay}) {
    my $start_time = Forks::Super::Util::Time() + $job->{delay};

    if ((not defined $job->{start_after}) || $job->{start_after} > $start_time) {
      $job->{start_after} = $start_time;
    }
    delete $job->{delay};
    debug('Forks::Super::Job::_can_launch(): start delay requested.')
      if $job->{debug};
  }
  return;
}

sub preconfig_dependencies {
  my $job = shift;

  ##########################
  # assert dependencies are expressed as array refs
  # expand job names to pids
  #
  if (defined $job->{depend_on}) {
    if (ref $job->{depend_on} eq '') {
      $job->{depend_on} = [ $job->{depend_on} ];
    }
    $job->{depend_on} = _resolve_names($job, $job->{depend_on});
  }
  if (defined $job->{depend_start}) {
    if (ref $job->{depend_start} eq '') {
      $job->{depend_start} = [ $job->{depend_start} ];
    }
    $job->{depend_start} = _resolve_names($job, $job->{depend_start});
  }
  return;
}

# convert job names in an array to job ids, if necessary
sub _resolve_names {
  my $job = shift;
  my @in = @{$_[0]};
  my @out = ();
  foreach my $id (@in) {
    if (is_number($id) && defined $ALL_JOBS{$id}) {
      push @out, $id;
    } else {
      my @j = Forks::Super::Job::getByName($id);
      if (@j > 0) {
	foreach my $j (@j) {
	  next if $j eq $job;
	  push @out, $j->{pid};
	}
      } else {
	carp "Forks::Super: Job ",
	  "dependency identifier \"$id\" is invaild. Ignoring\n";
      }
    }
  }
  return [ @out ];
}

#
# set some additional attributes of a Forks::Super::Job after the
# child is successfully launched.
#
sub config_parent {
  my $job = shift;
  $job->config_fh_parent;
  if (Forks::Super::Config::CONFIG("getpgrp")) {
    $job->{pgid} = getpgrp($job->{pid});

    # when  timeout =>   or   expiration =>  is used, PGID of child will be
    # set to child PID
    # XXX - tragically this is not always true. Do the parent settings matter
    #       though?
    if (defined $job->{timeout} or defined $job->{expiration}) {
      $job->{pgid} = $job->{real_pid};
    }
  }
  return;
}

sub config_child {
  my $job = shift;
  $Forks::Super::Job::self = $job;
  Forks::Super::Job::Callback::config_callback_child($job);
  $job->config_debug_child;
  $job->config_fh_child;
  Forks::Super::Job::Timeout::config_timeout_child($job);
  Forks::Super::Job::OS::config_os_child($job);
  return;
}

sub config_debug_child {
  my $job = shift;
  if ($job->{debug} && $job->{undebug}) {
    if (!$Forks::Super::IMPORT{":test"}) {
      debug("Disabling debugging in child $job->{pid}");
    }
    $Forks::Super::Debug::DEBUG = 0;
    $job->{debug} = 0;
  }
}

#
# Produces string representation of a Forks::Super::Job object.
#
sub toString {
  my $job = shift;
  my @to_display = qw(pid state create);
  foreach my $attr (qw(real_pid style cmd exec sub args start end reaped 
		       status closure pgid)) {
    push @to_display, $attr if defined $job->{$attr};
  }
  my @output = ();
  foreach my $attr (@to_display) {
    next unless defined $job->{$attr};
    if (ref $job->{$attr} eq 'ARRAY') {
      push @output, "$attr=[" . join(q{,},@{$job->{$attr}}) . ']';
    } else {
      push @output, "$attr=" . $job->{$attr};
    }
  }
  return '{' . join (q{;},@output), '}';
}

#
# Print information about all known jobs.
#
sub printAll {
  print "ALL JOBS\n";
  print "--------\n";
  foreach my $job
    (sort {$a->{pid} <=> $b->{pid} || 
	     $a->{created} <=> $b->{created}} @ALL_JOBS) {
      
      print $job->toString(), "\n";
      print "----------------------------\n";
    }
  return;
}

sub init_child {
  Forks::Super::Job::Ipc::init_child();
  return;
}

1;

__END__

# put POD here
