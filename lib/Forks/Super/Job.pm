#
# Forks::Super::Job - object representing a task to perform in
#                     a background process
# See the subpackages for some implementation details
#

package Forks::Super::Job;
use Forks::Super::Debug qw(debug);
use Forks::Super::Util qw(is_number qualify_sub_name);
use Forks::Super::Config qw(:all);
use Forks::Super::Job::Ipc;   # does windows prefer to load Ipc before Timeout?
use Forks::Super::Queue qw(queue_job);
use Forks::Super::Job::Timeout;
use Forks::Super::Job::OS;
use Forks::Super::Job::Callback qw(run_callback);
use Exporter;
use base 'Exporter';
use Carp;
use IO::Handle;
use strict;
use warnings;

our (@ALL_JOBS, %ALL_JOBS);
our @EXPORT = qw(@ALL_JOBS %ALL_JOBS);
our $VERSION = '0.32';

sub new {
  my ($class, $opts) = @_;
  my $this = {};
  if (ref $opts eq 'HASH') {
    $this->{$_} = $opts->{$_} foreach keys %$opts;
  }
  $this->{created} = Forks::Super::Util::Time();
  $this->{state} = 'NEW';
  $this->{ppid} = $$;
  if (!defined $this->{_is_bg}) {
    $this->{_is_bg} = 0;
  }
  if (!defined $this->{debug}) {
    $this->{debug} = $Forks::Super::Debug::DEBUG;
  }
  push @ALL_JOBS, $this;
  bless $this, 'Forks::Super::Job';
  if ($this->{debug}) {
    debug("New job created: ", $this->toString());
  }
  return $this;
}

sub is_complete {
  my $job = shift;
  return defined $job->{state} &&
    ($job->{state} eq 'COMPLETE' || $job->{state} eq 'REAPED');
}

sub is_started {
  my $job = shift;
  return $job->is_complete || $job->is_active || 
    (defined $job->{state} && $job->{state} eq 'SUSPENDED');
}

sub is_active {
  my $job = shift;
  return defined $job->{state} && $job->{state} eq 'ACTIVE';
}

sub is_suspended {
  my $job = shift;
  return defined $job->{state} && $job->{state} =~ /SUSPENDED/;
}

sub is_deferred {
  my $job = shift;
  return defined $job->{state} && $job->{state} =~ /DEFERRED/;
}

sub mark_complete {
  my $job = shift;
  $job->{state} = 'COMPLETE';
  $job->{end} = Forks::Super::Util::Time();

  $job->run_callback('collect');
  $job->run_callback('finish');
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

sub count_alive_processes {
  my ($count_bg, $optional_pgid) = @_;
  my @alive = grep { $_->{state} eq 'ACTIVE' ||
		     $_->{state} eq 'COMPLETE' ||
		     $_->{state} eq 'DEFERRED' ||
		     $_->{state} eq 'LAUNCHING' || # rare
		     $_->{state} eq 'SUSPENDED' ||
		     $_->{state} eq 'SUSPENDED-DEFERRED' 
		   } @ALL_JOBS;
  if (!$count_bg) {
    @alive = grep { $_->{_is_bg} == 0 } @alive;
  }
  if (defined $optional_pgid) {
    @alive = grep { $_->{pgid} == $optional_pgid } @alive;
  }
  return scalar @alive;
}

#
# _reap should distinguish:
#
#    all alive jobs (ACTIVE + COMPLETE + SUSPENDED + DEFERRED + SUSPENDED-DEFERRED)
#    all active jobs (ACTIVE + COMPLETE + DEFERRED)
#    filtered alive jobs (by optional pgid)
#    filtered ACTIVE + COMPLETE + DEFERRED jobs
#
#    if  all_active==0  and  all_alive>0,  
#    then see Wait::WAIT_ACTION_ON_SUSPENDED_JOBS
#
sub count_processes {
  my ($count_bg, $optional_pgid) = @_;
  my @alive = grep { $_->{state} ne 'REAPED' && $_->{state} ne 'NEW' } @ALL_JOBS;
  if (!$count_bg) {
    @alive = grep { $_->{_is_bg} == 0 } @alive;
  }
  my @active = grep { $_->{state} !~ /SUSPENDED/ } @alive;
  my @filtered_active = @active;
  if (defined $optional_pgid) {
    @filtered_active = grep { $_->{pgid} == $optional_pgid } @filtered_active;
  }

  my @n = (scalar(@filtered_active), scalar(@alive), scalar(@active));

  if ($Forks::Super::Debug::DEBUG) {
    debug("count_processes(): @n");
    debug("count_processes(): Filtered active: ",
	  $filtered_active[0]->toString()) if $n[0];
    debug("count_processes(): Alive: ", $alive[0]->toShortString()) if $n[1];
    debug("count_processes(): Active: @active") if $n[2];
  }

  return @n;
}

#
# get the current CPU load. May not be possible
# to do on all operating systems.
#
sub get_cpu_load {
  return Forks::Super::Job::OS::get_cpu_load();
}



#
# default function for determining whether the system
# is too busy to create a new child process or not
#
sub _can_launch {
  no warnings qw(once);

  my $job = shift;
  my $max_proc = defined $job->{max_proc}
    ? $job->{max_proc} : $Forks::Super::MAX_PROC;
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

  if ($max_load > 0) {
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

our ($WIN32_PROC, $WIN32_PROC_PID);
sub get_win32_proc { return $WIN32_PROC; }
sub get_win32_proc_pid { return $WIN32_PROC_PID; }

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

#  *STDIN->flush();
#  *STDOUT->flush();
#  *STDERR->flush();

  my $pid = CORE::fork();
  while (!defined $pid && --$retries > 0) {
    warn "Forks::Super::launch: ",
      "system fork call returned undef. Retrying ...\n";
    pause(1 + ($job->{retries} || 1) - $retries);
    $pid = CORE::fork();
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
    $job->run_callback('start');
    Forks::Super::Sigchld::handle_CHLD(-1);
    return $pid;
  } elsif ($pid != 0) {
    Carp::confess "Forks::Super::launch(): ",
	"Somehow we got pid=$pid from fork call.";
  }

  # child
  Forks::Super::init_child() if defined &Forks::Super::init_child;
  $job->config_child;
  if ($job->{style} eq 'cmd') {

    debug("Executing [ @{$job->{cmd}} ]") if $job->{debug};
    my $c1;
    if ($^O eq 'MSWin32') {
      local $ENV{_FORK_PPID} = $$;
      local $ENV{_FORK_PID} = $$;

      # There are lots of ways to spawn a process in Windows
      if (1 && Forks::Super::Config::CONFIG('Win32::Process')) {
	$c1 = Forks::Super::Job::OS::Win32::open_win32_process($job);
      } elsif (1 && Forks::Super::Config::CONFIG('Win32::Process')) {
	$c1 = Forks::Super::Job::OS::Win32::open2_win32_process($job);
      } elsif (1) {
	$c1 = Forks::Super::Job::OS::Win32::open3_win32_process($job);
      } elsif (0 && Forks::Super::Config::CONFIG('Win32::Process')) {
	$c1 = Forks::Super::Job::OS::Win32::create_win32_process($job);
      } else {
	$c1 = Forks::Super::Job::OS::Win32::system_win32_process($job);
      }
    } else {
      $c1 = system( @{$job->{cmd}} );
    }
    debug("Exit code of $$ was $c1") if $job->{debug};
    deinit_child();
    exit $c1 >> 8;
  } elsif ($job->{style} eq 'exec') {
    local $ENV{_FORK_PPID} = $$;
    local $ENV{_FORK_PID} = $$;
    debug("Exec'ing [ @{$job->{exec}} ]") if $job->{debug};
    exec( @{$job->{exec}} );
  } elsif ($job->{style} eq 'sub') {
    no strict 'refs';
    $job->{sub}->(@{$job->{args}});
    debug("Job $$ subroutine call has completed") if $job->{debug};
    deinit_child();
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

sub suspend {
  my $j = shift;
  $j = Forks::Super::Job::get($j) if ref $j ne 'Forks::Super::Job';
  my $pid = $j->{real_pid};
  if ($j->{state} eq 'ACTIVE') {
    local $! = 0;
    my $kill_result = Forks::Super::kill('STOP', $j);
    if ($kill_result > 0) {
      $j->{state} = 'SUSPENDED';
      return 1;
    }
    carp "'STOP' signal not received by $pid, job ", $j->toString(), "\n";
    return;
  }
  if ($j->{state} eq 'DEFERRED') {
    $j->{state} = 'SUSPENDED-DEFERRED';
    return -1;
  }
  if ($j->is_complete) {
    carp "Forks::Super::Job::suspend(): called on completed job ", 
      $j->{pid}, "\n";
    return;
  }
  if ($j->{state} eq 'SUSPENDED') {
    carp "Forks::Super::Job::suspend(): called on suspended job ", 
      $j->{pid}, "\n";
    return;
  }
  carp "Forks::Super::Job::suspend(): called on job ", $j->toString(), "\n";
  return;
}

sub resume {
  my $j = shift;
  $j = Forks::Super::Job::get($j) if ref $j ne 'Forks::Super::Job';
  my $pid = $j->{real_pid};
  if ($j->{state} eq 'SUSPENDED') {
    local $! = 0;
    my $kill_result = Forks::Super::kill('CONT', $j);
    if ($kill_result > 0) {
      $j->{state} = 'ACTIVE';
      return 1;
    }
    carp "'CONT' signal not received by $pid, job ", $j->toString(), "\n";
    return;
  }
  if ($j->{state} eq 'SUSPENDED-DEFERRED') {
    $j->{state} = 'DEFERRED';
    return -1;
  }
  if ($j->is_complete) {
    carp "Forks::Super::Job::resume(): called on a completed job ", 
      $j->{pid}, "\n";
    return;
  }
  carp "Forks::Super::Job::resume(): called on job in state ", 
    $j->{state}, "\n";
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
  Forks::Super::Job::OS::preconfig_os($job);
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
    $job->{style} = 'cmd';
  } elsif (defined $job->{exec}) {
    if (ref $job->{exec} eq '') {
      $job->{exec} = [ $job->{exec} ];
    }
    $job->{style} = 'exec';
  } elsif (defined $job->{sub}) {
    $job->{style} = 'sub';
    $job->{sub} = qualify_sub_name $job->{sub};
    if (defined $job->{args}) {
      if (ref $job->{args} eq '') {
	$job->{args} = [ $job->{args} ];
      }
    } else {
      $job->{args} = [];
    }
  } else {
    $job->{style} = 'natural';
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
    no warnings 'once';
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

    if ((not defined $job->{start_after}) 
	|| $job->{start_after} > $start_time) {
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
  if (Forks::Super::Config::CONFIG('getpgrp')) {
    $job->{pgid} = getpgrp($job->{real_pid});

    # when  timeout =>   or   expiration =>  is used,
    # PGID of child will be set to child PID
    # XXX - tragically this is not always true. Do the parent settings matter
    #       though? Should comment out these lines and test
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
  Forks::Super::Job::Timeout::config_timeout_child($job);
  Forks::Super::Job::OS::config_os_child($job);
  $job->config_fh_child;
  return;
}

sub config_debug_child {
  my $job = shift;
  if ($job->{debug} && $job->{undebug}) {
    if (Forks::Super::_is_test()) {
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
		       status closure pgid child_fh queue_priority)) {
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
  return '{' . join ( ';' , @output), '}';
}

sub toShortString {
  my $job = shift;
  if (defined $job->{short_string}) {
    return $job->{short_string};
  }
  my @to_display = ();
  foreach my $attr (qw(pid state cmd exec sub args closure real_pid)) {
    push @to_display, $attr if defined $job->{$attr};
  }
  my @output;
  foreach my $attr (@to_display) {
    if (ref $job->{$attr} eq 'ARRAY') {
      push @output, "$attr=[" . join(",", @{$job->{$attr}}) . "]";
    } else {
      push @output, "$attr=" . $job->{$attr};
    }
  }
  return $job->{short_string} = "{" . join(";",@output) . "}";
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

sub deinit_child {
  Forks::Super::Job::Ipc::deinit_child();
  close STDOUT if -p STDOUT;
  close STDERR if -p STDERR;
  close STDIN if *STDIN->opened && -p STDIN;
}

1;

__END__

=head1 NAME

Forks::Super::Job - object representing a background task

=head1 VERSION

0.32

=head1 SYNOPSIS

    use Forks::Super;

    $pid = Forks::Super::fork( \%options );  # see Forks::Super
    $job = Forks::Super::Job::get($pid);
    $job = Forks::Super::Job::getByName($name);
    print "Current job state is $job->{state}\n";
    print "Job was created at ", scalar localtime($job->{created}), "\n";

=head1 DESCRIPTION

Calls to C<Forks::Super::fork> that successfully spawn a child process or
create a L<deferred job|Forks::Super/"Deferred processes"> will cause 
a C<Forks::Super::Job> instance to be created to track the job's state. 
For many uses of C<fork>, it will not be necessary to query the state of 
a background job. But access to these objects is provided for users who 
want to exercise even greater control over their use of background
processes.

Calls to C<Forks::Super::fork> that fail (return C<undef> or small negative
numbers) generally do not cause a new C<Forks::Super::Job> instance
to be created.

=head1 ATTRIBUTES

Use the C<Forks::Super::Job::get> or C<Forks::Super::Job::getByName>
methods to obtain a Forks::Super::Job object for
examination. The C<Forks::Super::Job::get> method takes a process ID or
job ID as an input (a value that may have been returned from a previous
call to C<Forks::Super::fork> and returns a reference to a C<Forks::Super::Job>
object, or C<undef> if the process ID or job ID was not associated
with any known Job object. The C<Forks::Super::Job::getByName> looks up
job objects by the C<name> parameter that may have been passed
in the C<Forks::Super::fork> call.

A C<Forks::Super::Job> object has many attributes, some of which may
be of interest to an end-user. Most of these should not be overwritten.

=over 4

=item pid

Process ID or job ID. For deferred processes, this will be a
unique large negative number (a job ID). For processes that
were not deferred, this valud is the process ID of the
child process that performed this job's task.

=item real_pid

The process ID of the child process that performed this job's
task. For deferred processes, this value is undefined until
the job is launched and the child process is spawned.

=item pgid

The process group ID of the child process. For deferred processes,
this value is undefined until the child process is spawned. It is
also undefined for systems that do not implement
L<getpgrp|perlvar/"getpgrp">.

=item created

The time (since the epoch) at which the instance was created.

=item start

The time at which a child process was created for the job. This
value will be undefined until the child process is spawned.

=item end

The time at which the child process completed and the parent
process received a C<SIGCHLD> signal for the end of this process.
This value will be undefined until the child process is complete.

=item reaped

The time at which a job was reaped via a call to
C<Forks::Super::wait>, C<Forks::Super::waitpid>, 
or C<Forks::Super::waitall>. Will be undefined until 
the job is reaped.

=item state

A string value indicating the current state of the job.
Current allowable values are

=over 4

=item C<DEFERRED>

For jobs that are on the job queue and have not started yet.

=item C<ACTIVE>

For jobs that have started in a child process

=item C<COMPLETE>

For jobs that have completed and caused the parent process to
receive a C<SIGCHLD> signal, but have not been reaped.

=item C<REAPED>

For jobs that have been reaped by a call to C<Forks::Super::wait>,
C<Forks::Super::waitpid>, or C<Forks::Super::waitall>.

=item C<SUSPENDED>

The job has started but it has been suspended (with a C<SIGSTOP>
or other appropriate mechanism for your operating system) and
is not currently running. A suspended job will not consume CPU
resources but my tie up memory, I/O, and network resources.

=item C<SUSPENDED-DEFERRED>

Job is in the job queue and has not started yet, and also
the job has been suspended.

=back

=item status

The exit status of a job. See L<CHILD_ERROR|perlvar/"CHILD_ERROR"> in
C<perlvar>. Will be undefined until the job is complete.

=item style

One of the strings C<natural>, C<cmd>, or C<sub>, indicating
whether the initial C<fork> call returned from the child process or whether
the child process was going to run a shell command or invoke a Perl
subroutine and then exit.

=item cmd

The shell command to run that was supplied in the C<fork> call.

=item sub

=item args

The name of or reference to CODE to run and the subroutine
arguments that were supplied in the C<fork> call.

=item _on_busy

The behavior of this job in the event that the system was
too "busy" to enable the job to launch. Will have one of
the string values C<block>, C<fail>, or C<queue>.

=item queue_priority

If this job was deferred, the relative priority of this
job.

=item can_launch

By default undefined, but could be a CODE reference
supplied in the C<fork()> call. If defined, it is the
code that runs when a job is ready to start to determine
whether the system is too busy or not.

=item depend_on

If defined, contains a list of process IDs and job IDs that
must B<complete> before this job will be allowed to start.

=item depend_start

If defined, contains a list of process IDs and job IDs that
must B<start> before this job will be allowed to start.

=item start_after

Indicates the earliest time (since the epoch) at
which this job may start.

=item expiration

Indicates the latest time that this job may be allowed to
run. Jobs that run past their expiration parameter will
be killed.

=item os_priority

Value supplied to the C<fork> call about desired
operating system priority for the job.

=item cpu_affinity

Value supplied to the C<fork> call about desired
CPU's for this process to prefer.

=back

=cut

+head1 FUNCTIONS

+over 4

+item C< $job = Forks::Super::Job::get($pidOrName) >

+item C< $n = Forks::Super::Job::count_active_processes() >

+back

+head1 METHODS

The following methods may be called on a C<Forks::Super::Job> object.

+over 4

+item C<< $job->suspend >>

When called on an active job, suspends the background process with 
C<SIGSTOP> or other mechanism appropriate for the operating system.

+item C<< $job->resume >>

+item C<< $job->is_complete >>

Indicates whether the job is in the C<COMPLETE> or C<REAPED> state.

+item C<< $job->is_started >>

+item C<< $job->toString() >>
+item C<< $job->toShortString() >>

+back

=head1 SEE ALSO

L<Forks::Super>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2010, Marty O'Brien.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
