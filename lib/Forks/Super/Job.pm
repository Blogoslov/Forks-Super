#
# Forks::Super::Job - object representing a task to perform in
#                     a background process
# See the subpackages for some implementation details
#

package Forks::Super::Job;
use Forks::Super::Debug qw(debug);
use Forks::Super::Util qw(is_number qualify_sub_name IS_WIN32 is_pipe);
use Forks::Super::Config qw(:all);
use Forks::Super::Job::Ipc;   # does windows prefer to load Ipc before Timeout?
use Forks::Super::Job::Timeout;
use Forks::Super::Queue qw(queue_job);
use Forks::Super::Job::OS;
use Forks::Super::Job::Callback qw(run_callback);
use Signals::XSIG;
use Exporter;
use POSIX ':sys_wait_h';
use Carp;
use Cwd;
use IO::Handle;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT = qw(@ALL_JOBS %ALL_JOBS);
our $VERSION = '0.53';

our (@ALL_JOBS, %ALL_JOBS, $WIN32_PROC, $WIN32_PROC_PID);
our $OVERLOAD_ENABLED = 0;
our $INSIDE_END_QUEUE = 0;
our $_RETRY_PAUSE;

my $use_overload = $ENV{FORKS_SUPER_JOB_OVERLOAD};
if (!defined($use_overload)) {
  $use_overload = 1;
}
if ($use_overload) {
  enable_overload();
} else {
  enable_overload();
  disable_overload();
}

#############################################################################
# Object methods (meant to be called as $job->xxx(@args))

sub new {
  my ($class, $opts) = @_;
  my $this = {};
  if (ref $opts eq 'HASH') {
      if (0 && $opts->{untaint}) {
	  if ($opts->{env} && ref($opts->{env}) eq 'HASH') {
	      foreach my $k (%{$opts->{env}}) {
		  ($opts->{env}{$k}) = $opts->{env}{$k}=~/(.*)/s;
	      }
	  }
      }


      foreach (keys %$opts) {
	  $this->{$_} = $opts->{$_} ;
      }
  }

  $this->{__opts__} = $opts;

  $this->{created} = Time::HiRes::time();
  $this->{state} = 'NEW';
  $this->{ppid} = $$;
  if (!defined $this->{_is_bg}) {
      $this->{_is_bg} = 0;
  }
  if (!defined $this->{debug}) {
      $this->{debug} = $Forks::Super::Debug::DEBUG;
  }
  # 0.41: fix overload bug here by putting  bless  before  push @ALL_JOBS
  bless $this, 'Forks::Super::Job';
  push @ALL_JOBS, $this;
  if ($this->{debug}) {
      debug("New job created: ", $this->toString());
  }
  return $this;
}

sub reuse {
  my ($job, $opts) = @_;
  if (ref $opts ne 'HASH') {
    $opts = { @_[1..$#_] };
  }
  my %opts;
  if (defined $job->{__opts__}) {
    %opts = %{$job->{__opts__}};
  }
  for (keys %$opts) {
    $opts{$_} = $opts->{$_};
  }

  return Forks::Super::fork( \%opts ) ;
}

sub is_complete {
    my $job = shift;
    my $state = $job->state;
    return defined($state) &&
	($state eq 'COMPLETE' || 
	 $state eq 'REAPED' || 
	 $state eq 'DAEMON-COMPLETE');
}

sub is_started {
  my $job = shift;
  return $job->is_complete || $job->is_active || 
      (defined($job->{state}) &&
       ($job->{state} eq 'SUSPENDED' || $job->{state} eq 'DAEMON-SUSPENDED'));
}

sub is_active {
  my $job = shift;
  my $state = $job->state;
  return defined($state) && ($state eq 'ACTIVE' || $state eq 'DAEMON');
}

sub is_suspended {
  my $job = shift;
  return defined($job->{state}) && $job->{state} =~ /SUSPENDED/;
}

sub is_deferred {
  my $job = shift;
  return defined($job->{state}) && $job->{state} =~ /DEFERRED/;
}

sub is_daemon {
    my $job = shift;
    return !!$job->{daemon};
}

sub waitpid {
  my ($job, $flags, $timeout) = @_;
  return Forks::Super::Wait::waitpid($job->{pid}, $flags, $timeout || 0);
}

sub wait {
  my ($job, $timeout) = @_;
  if (defined($timeout) && $timeout == 0) {
    return Forks::Super::Wait::waitpid($job->{pid}, &WNOHANG);
  }
  return Forks::Super::Wait::waitpid($job->{pid}, 0, $timeout || 0);
}

sub kill {
  my ($job, $signal) = @_;
  if (!defined($signal) || $signal eq '') {
    $signal = Forks::Super::Util::signal_number('INT') || 1;
  }
  return Forks::Super::kill($signal, $job);
}

sub state {
  my $job = shift;
  if ($job->{daemon} && $job->{state} ne 'DAEMON-COMPLETE') {

      # if current state is DAEMON or DAEMON-SUSPENDED,
      # inspect the process table or use SIGZERO to see
      # if the daemon is still active

  }
  return $job->{state};
}

sub status {
  my $job = shift;
  return $job->{status};  # may be undefined
}

sub exit_status {
    my $job = shift;
    return if !defined $job->{status};
    my $coredump = $job->{status} & 128 ? 1 : 0;
    my $signal = $job->{status} & 127;
    my $exit_status = $job->{status} >> 8;
    if (wantarray) {
	return ($exit_status, $signal, $coredump);
    } elsif ($signal || $coredump) {
	return -$signal - 128*$coredump;
    } else {
	return $exit_status;
    }
}

#
# Produces string representation of a Forks::Super::Job object.
#
sub toString {
  my $job = shift;
  my @to_display = qw(pid state create);
  foreach my $attr (qw(real_pid style cmd exec sub args dir start end reaped
		       status closure pgid child_fh queue_priority
		       timeout expiration)) {
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

sub toFullString {
  my $job = shift;
  my @output = ();
  foreach my $attr (sort keys %$job) {
    next unless defined $job->{$attr};
    if (ref $job->{$attr} eq 'ARRAY') {
      push @output, "$attr=[" . join(',', @{$job->{$attr}}) . ']';
    } elsif (ref $job->{$attr} eq 'HASH') {
      push @output, "$attr={", 
	join(',', map {"$_=>$job->{$attr}{$_}"
		     } sort keys %{$job->{$attr}}), '}';
    } else {
      push @output, "$attr=$job->{$attr}";
    }
  }
  return '{' . join(';', @output), '}';
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

sub _mark_complete {
  my $job = shift;
  $job->{end} = Time::HiRes::time();
  $job->{state} = 'COMPLETE';

  $job->run_callback('share');
  $job->run_callback('collect');
  $job->run_callback('finish');
  return;
}

sub _mark_reaped {
  my $job = shift;
  $job->{state} = 'REAPED';
  $job->{reaped} = Time::HiRes::time();
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
  $job->{last_check} = Time::HiRes::time();
  if (defined $job->{can_launch}) {
    if (ref $job->{can_launch} eq 'CODE') {
      return $job->{can_launch}->($job);
    } elsif (ref $job->{can_launch} eq '') {
      my $can_launch_sub = $job->{can_launch};
      return $can_launch_sub->($job);
    }
  } else {
    return $job->_can_launch;
  }
}

sub _can_launch_delayed_start_check {
  my $job = shift;
  return 1 if !defined($job->{start_after}) ||
    Time::HiRes::time() >= $job->{start_after};

  debug('_can_launch(): start delay requested. launch fail') if $job->{debug};

  # delay option should normally be associated with queue on busy behavior.
  # any reason not to make this the default ?
  #  delay + fail   is pretty dumb
  #  delay + block  is like sleep + fork

  $job->{_on_busy} = 'QUEUE' if not defined $job->{on_busy};
  return 0;
}

sub _can_launch_dependency_check {
  my $job = shift;
  my @dep_on = defined($job->{depend_on}) ? @{$job->{depend_on}} : ();
  my @dep_start = defined($job->{depend_start}) ? @{$job->{depend_start}} : ();

  foreach my $dj (@dep_on) {
    my $j = $ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Forks::Super::Job: ",
	"dependency $dj for job $job->{pid} is invalid. Ignoring.\n";
      next;
    }
    unless ($j->is_complete) {
      debug("_can_launch(): ",
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
      debug('_can_launch(): ',
	"job waiting for job $j->{pid} to start. launch fail.")
	if $j->{debug};
      return 0;
    }
  }
  return 1;
}

#
# default function for determining whether the system
# is too busy to create a new child process or not
#
sub _can_launch {
  no warnings qw(once);

  my $job = shift;
  my $max_proc = defined($job->{max_proc})
    ? $job->{max_proc} : $Forks::Super::MAX_PROC;
  my $max_load = defined($job->{max_load})
    ? $job->{max_load} : $Forks::Super::MAX_LOAD;
  my $force = defined($job->{max_load}) && $job->{force};

  if ($force) {
    debug('_can_launch(): force attr set. launch ok')
      if $job->{debug};
    return 1;
  }

  return 0 if not $job->_can_launch_delayed_start_check;
  return 0 if not $job->_can_launch_dependency_check;

  if ($max_proc > 0) {
    my $num_active = count_active_processes();
    if ($num_active >= $max_proc) {
      debug('_can_launch(): ',
	"active jobs $num_active exceeds limit $max_proc. ",
	    'launch fail.') if $job->{debug};
      return 0;
    }
  }

  if ($max_load > 0) {
    my $load = get_cpu_load();
    if ($load > $max_load) {
      debug('_can_launch(): ',
	"cpu load $load exceeds limit $max_load. launch fail.")
	if $job->{debug};
      return 0;
    }
  }

  debug('_can_launch(): system not busy. launch ok.')
    if $job->{debug};
  return 1;
}

# Perl system fork() call. Encapsulated here so it can be overridden 
# and mocked for testing. See t/17-retries.t
sub _CORE_fork { return CORE::fork }

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

  if ($$ != $Forks::Super::MAIN_PID && $Forks::Super::CHILD_FORK_OK > 0) {
    $Forks::Super::MAIN_PID = $$;
    $Forks::Super::CHILD_FORK_OK--;
  }

  if ($$ != $Forks::Super::MAIN_PID && $Forks::Super::CHILD_FORK_OK <= 0) {
    return _launch_from_child($job);
  }
  $job->_preconfig_fh;
  $job->_preconfig2;
  $job->{cwd} = &Cwd::getcwd;

  my $retries = $job->{retries} || 0;




  ######################################################################
  # the other 11,000 lines in this module are just a wrapper for this:
  
  my $pid = _CORE_fork();
  while (!defined($pid) && $retries-- > 0) {
    warn "Forks::Super::launch: ",
      "system fork call returned undef. Retrying ...\n";
    $_RETRY_PAUSE ||= 1.0;
    my $delay = 1.0 + $_RETRY_PAUSE * (($job->{retries} || 1) - $retries);
    Forks::Super::Util::pause($delay);
    $pid = _CORE_fork();
  }

  # :-)
  #####################################################################






  if (!defined $pid) {
    debug('launch(): CORE::fork() returned undefined!')
      if $job->{debug};
    return;
  }


  if (Forks::Super::Util::isValidPid($pid)) {

    # parent
    return _postlaunch_parent($pid, $job);

  } elsif ($pid == 0) {

      if ($job->{daemon}) {
	  if (&IS_WIN32) {
	      $job->_postlaunch_daemon_Win32;
	  } else {
	      $job->_postlaunch_daemon;
	  }
      }
      if ($job->{daemon}) {
      }

      _postlaunch_child($job);
      return 0;

  } else {

    Carp::confess "Forks::Super::launch(): ",
	"Somehow we got invalid pid=$pid from fork call.";
    return;

  }
}

sub _postlaunch_parent {
  my ($pid, $job) = @_;

  $ALL_JOBS{$pid} = $job;
  if (defined($job->{state}) &&
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
    # handler should have made an entry in %Forks::Super::Sigchld::BASTARD_DATA
    # for this process.
    #
    Forks::Super::Sigchld::handle_bastards($pid);
  }
  if ($job->{daemon}) {
      $job->{state} = 'DAEMON';
      my $new_pid;
      for (my $try=1; defined($job->{daemon_ipc}) && $try<=10; $try++) {
	  if (-f $job->{daemon_ipc}) {
	      open my $fh, '<', $job->{daemon_ipc};
	      $new_pid = <$fh>;
	      close $fh;
	      unlink $job->{daemon_ipc};
	      ($new_pid) = $new_pid =~ /([-\d]*)/;
	      last;
	  }
	  Forks::Super::Util::pause(0.002*$try*$try*$try,$try<3);
      }
      if ($new_pid) {
	  $job->{intermediate_pid} = $pid;
	  delete $ALL_JOBS{$pid};
	  $ALL_JOBS{$new_pid} = $job;
	  $pid = $new_pid;
      } elsif (!defined $new_pid) {
	  carp "Forks::Super::fork: ",
	      "unable to get process ID for new daemon process. ",
	      "It is possible the daemon fork failed. ",
	      "Signalling and other IPC with this process may be unreliable.";
      }
  }


  $job->{real_pid} = $pid;
  $job->{pid} = $pid unless defined $job->{pid};
  $job->{start} = Time::HiRes::time();

  $job->_config_parent;
  $job->run_callback('start');

  Forks::Super::handle_CHLD(-1);
  if ($$ != $Forks::Super::MAIN_PID) {
      # Forks::Super::fork call from a child.
      $XSIG{CHLD}[-1] ||= \&Forks::Super::handle_CHLD;
  }

  return $OVERLOAD_ENABLED ? $job : $pid;
}

sub _postlaunch_daemon_Win32 {
    my $job = shift;
    debug("child $$ forking again to create daemon process")
	if $Forks::Super::Debug::DEBUG;

    if ($job->{style} ne 'cmd' && $job->{style} ne 'exec') {
	carp "Forks::Super::fork: 'daemon' option on MSWin32 ",
	    "must also use 'cmd' or 'exec' option";
	return;
    }

    use POSIX ();
    umask 0;

    my $p = $$;
    my $p2 = _CORE_fork();

    if ($p == $$) {
	# intermediate child
	if (defined $p2) {
	    no warnings 'io';
	    my $f = $job->{daemon_ipc};
	    open my $fh, '>', "$f.tmp";
	    print $fh $p2;
	    close $fh;
	    rename "$f.tmp", $f;
	    if ($Forks::Super::Debug::DEBUG) {
		debug("daemon pid is $p2");
	    }
	} else {
	    croak "Forks::Super::fork: ",
	        "Unable to create daemon process because secondary fork failed";
	}
	exit;
    }
    # orphaned grandchild - the new daemon process

    # XXX - In MSWin32, close filehandles after second fork? Or not at all?
    #  close $_ for *STDIN,*STDOUT,*STDERR;

    if ($job->{name}) {
	$0 = $job->{name};
    }
    chdir "/";
    sleep 1;
}

sub _postlaunch_daemon {
    my $job = shift;
    debug("child $$ forking again to create daemon process")
	if $Forks::Super::Debug::DEBUG;

    # XXX - brute force and ignorant way to close open fds
    POSIX::close($_) for 0..999;
    eval { POSIX::setsid };
    umask 0;

    my $p = $$;
    my $p2 = _CORE_fork();

    if ($p == $$) {
	# intermediate child
	if (defined $p2) {
	    no warnings 'io';
	    my $f = $job->{daemon_ipc};
	    open my $fh, '>', "$f.tmp";
	    print $fh $p2;
	    close $fh;
	    rename "$f.tmp", $f;
	} else {
	    croak "Forks::Super::fork: ",
	        "Unable to create daemon process because secondary fork failed";
	}
	exit;
    }
    # orphaned grandchild - the new daemon process
    if ($job->{name}) {
	$0 = $job->{name};
    }
    chdir "/";
    sleep 1;
}

sub _postlaunch_child {
  my $job = shift;
  Forks::Super::init_child() if defined &Forks::Super::init_child;
  $job->_config_child;

  local $ENV{_FORK_PPID} = $$;
  local $ENV{_FORK_PID} = $$;

  if ($job->{style} eq 'cmd' || $job->{style} eq 'exec') {

      if (defined($job->{fh_config}->{stdin})
	  && defined($job->{fh_config}->{sockets})) {

	  $job->_postlaunch_child_to_proc;

      } elsif ($job->{style} eq 'cmd') {

	  $job->_postlaunch_child_to_cmd;

      } else {

	  $job->_postlaunch_child_to_exec;

      }

  } elsif ($job->{style} eq 'sub') {

      $job->_postlaunch_child_to_sub;

  }
  return 0;
}

sub _postlaunch_child_to_exec {
    my $job = shift;
    debug("Exec'ing [ @{$job->{exec}} ]") if $job->{debug};

    if (!&IS_WIN32) {
	exec( @{$job->{exec}} )
	    or croak "exec failed for ", $job->toString(), 
	             " command ",@{$job->{exec}};
    }

    # Windows needs special handling. An  exec  call from a Windows child
    # process will actually spawn a new process (a real process, not a
    # pseudo-process) and its process id will be unavailable to both
    # the child and the parent process.
    #
    # system 1, ...  is a decent workaround
    # 
    $WIN32_PROC_PID = system 1, @{$job->{exec}};

    $job->set_signal_pid($WIN32_PROC_PID);
    if (0 && $job->{daemon}) {
	deinit_child();
	exit 0;
    }

    my $z = CORE::waitpid $WIN32_PROC_PID, 0;
    my $c1 = $?;
    if ($Forks::Super::Debug::DEBUG) {
	debug("waitpid $WIN32_PROC_PID ==> $z");
    }
    deinit_child();
    exit $c1 >> 8;
}

sub _postlaunch_child_to_proc {
    my $job = shift;
    my $proch = Forks::Super::Job::Ipc::_gensym();
    $job->{cmd} ||= $job->{exec};
    my $p1 = open $proch, '|-', @{$job->{cmd}};
    print $proch $job->{fh_config}->{stdin};
    close $proch;
    my $c1 = $?;
    debug("Exit code of $$ was $c1 ", $c1>>8) if $job->{debug};
    deinit_child();
    exit $c1 >> 8;
}

sub _postlaunch_child_to_cmd {
    my $job = shift;
    debug("Executing command [ @{$job->{cmd}} ]") if $job->{debug};

    my $c1;
    if (&IS_WIN32) {

	if (1) {
	    $c1 = Forks::Super::Job::OS::Win32::system1_win32_process(
				$job, @{$job->{cmd}});
	} else {
	    debug("using  system 1,... ") if $job->{debug};
	    $WIN32_PROC_PID = system 1, @{$job->{cmd}};
	    $job->set_signal_pid($WIN32_PROC_PID);
	    $job->{exec_pid} = $WIN32_PROC_PID;
	    debug("exec/signal pid is $WIN32_PROC_PID") if $job->{debug};
	    debug("child is waiting on $WIN32_PROC_PID") if $job->{debug};
	    my $z = CORE::waitpid $WIN32_PROC_PID, 0;
	    $c1 = $?;
	    debug("waitpid returned $z, exit status $c1") if $job->{debug};
	}

    } else {

	my $this_pid = $$;
	my $exec_pid = _CORE_fork();
	if ($$ != $this_pid) {
	    exec( @{$job->{cmd}} );
	    die "exec for cmd-style fork failed ";
	}
	$job->set_signal_pid($exec_pid);
	$job->{exec_pid} = $exec_pid;

	my $z = CORE::waitpid $exec_pid, 0;
	$c1 = $?;
	debug("waitpid returned $z, exit code of $$ was $c1 ", $c1>>8)
	    if $job->{debug};
    }
    deinit_child();
    exit $c1 >> 8;
}

sub _postlaunch_child_to_sub {
    my $job = shift;
    my $sub = $job->{sub};
    my @args = @{$job->{args} || []};

    my $error;
    eval {
      no strict 'refs';
      $job->{_cleanup_code} = \&deinit_child;
      $sub->(@args);
      delete $job->{_cleanup_code};
      1;
    } or do {
      $error = $@;
    };
 
    if ($job->{debug}) {
      if ($error) {
	debug("JOB $$ SUBROUTINE CALL HAD AN ERROR: $error");
      }
      debug("Job $$ subroutine call has completed");
    }
    deinit_child();
    if ($error) {
	die $error,"\n";
    }
    exit 0;
}

sub _launch_from_child {
  my $job = shift;
  if ($Forks::Super::CHILD_FORK_OK == 0) {
    carp "Forks::Super::fork() not allowed\n",
        "in child process $$ while \$Forks::Super::CHILD_FORK_OK ",
	"is not set!\n";

    return;
  } elsif ($Forks::Super::CHILD_FORK_OK < 0) {
    carp "Forks::Super::fork() call not allowed\n",
	"in child process $$ while \$Forks::Super::CHILD_FORK_OK <= 0.\n",
	  "Will create child of child with CORE::fork()\n";

    my $pid = _CORE_fork();
    if (defined($pid) && $pid == 0) {
      # child of child
      if (defined &Forks::Super::init_child) {
	Forks::Super::init_child();
      } else {
	init_child();
      }
      # return $pid;
    }
    return $pid;
  }
  return;
}

sub set_signal_pid {
    # called from child. signal_pid will be called from the parent
    my ($job, $signal_pid) = @_;
    $job->{signal_pid} = $signal_pid;

    no warnings 'io';  # Win32 can open fd 0, trigger "reopen STDIN for output"
    if (defined $job->{signal_ipc}) {
	open my $fh, '>', $job->{signal_ipc} . ".tmp";
	print $fh $signal_pid;
	close $fh;
	rename $job->{signal_ipc} . ".tmp", $job->{signal_ipc};
	if ($job->{debug}) {
	    debug("Signal pid for $$ is $signal_pid");
	}
    } elsif (0) {
	no warnings 'uninitialized';
	carp "Forks::Super::set_signal_pid: signal IPC file not specified ",
	    "for job $job->{pid} to deliver signal pid $signal_pid ",
	    "to its parent";
    }
    return;
}

sub signal_pids {
    # if a background job has spawned yet another process,
    # then sometimes we want to send a signal to both of those processes ...

    my $job = shift;
    my $signal_pid = $job->signal_pid;

    if (defined $job->{real_pid} && $job->{real_pid} != $signal_pid) {
	if ($Forks::Super::Debug::DEBUG) {
	    debug("signal pids for $job are $signal_pid,", $job->{real_pid});
	}
#	return ($signal_pid, $job->{real_pid});
	return ($job->{real_pid}, $signal_pid);
    } else {
	if ($Forks::Super::Debug::DEBUG) {
	    debug("signal pids for $job is $signal_pid");
	}
	return ($signal_pid);
    }
}

sub signal_pid {
    my $job = shift;

    if ($job->{signal_ipc} && !defined $job->{signal_pid}) {
	if (!defined $job->{signal_pid}) {
	    for (my $try=1; $try<=5; $try++) {
		last if -f $job->{signal_ipc};
		Forks::Super::Util::pause(0.002*$try*$try*$try, $try<3);
	    }
	}
	if (-f $job->{signal_ipc}) {
	    open my $fh, '<', $job->{signal_ipc};
	    my $signal_pid = <$fh>;
	    close $fh;
	    unlink $job->{signal_ipc};
	    # delete $job->{signal_ipc};
	    ($job->{signal_pid}) = $signal_pid =~ /([-\d]*)/;
	    if ($Forks::Super::Debug::DEBUG) {
		debug("parent forwarding signals for ", $job->{real_pid},
		      " to ", $job->{signal_pid});
	    }
	} elsif ($job->{debug}) {
	    debug("no ", $job->{signal_ipc}, " signal ipc file ...");
	}
    }
    if ($job->{debug} && defined $job->{signal_pid}) {
	debug("job $job will send signal to ", $job->{signal_pid});
    }
    return $job->{signal_pid} || $job->{real_pid};
}

sub suspend {
  my $j = shift;
  $j = Forks::Super::Job::get($j) if ref $j ne 'Forks::Super::Job';
  #my $pid = $j->{real_pid};
  my $pid = $j->signal_pid;
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
  if ($j->{state} =~ /DAEMON/ && $j->{state} ne 'DAEMON-COMPLETE') {
      $j->{state} = 'SUSPENDED-DAEMON';
      my $kill_result = Forks::Super::kill('STOP', $j);
      return $kill_result;
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
    carp "Forks::Super::Job: suspend called on suspended job ", $j->{pid};
    return;
  }
  carp "Forks::Super::Job: suspend called on job ", $j->toString(), "\n";
  return;
}

sub resume {
  my $j = shift;
  $j = Forks::Super::Job::get($j) if ref $j ne 'Forks::Super::Job';
  my $pid = $j->signal_pid;
  #my $pid = $j->{real_pid};
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
  if ($j->{daemon} && $j->{state} !~ /COMPLETE/) {
      my $kill_result = Forks::Super::kill('CONT', $j);
      $j->{state} = 'DAEMON';
      return $kill_result;
  }
  carp "Forks::Super::Job::resume(): called on job in state ", 
    $j->{state}, "\n";
  return;
}

#
# do further initialization of a Forks::Super::Job object,
# mainly setting derived fields
#
sub _preconfig {
  my $job = shift;

  $job->_preconfig_style;
  $job->_preconfig_dir;
  $job->_preconfig_busy_action;
  $job->_preconfig_start_time;
  $job->_preconfig_dependencies;
  $job->_preconfig_share;
  Forks::Super::Job::Callback::_preconfig_callbacks($job);
  Forks::Super::Job::OS::_preconfig_os($job);
  return;
}

# some final initialization just before launch
sub _preconfig2 {
    my $job = shift;
    if (!defined $job->{debug}) {
	$job->{debug} = $Forks::Super::Debug::DEBUG;
    }
    if ($job->{daemon}) {
	$job->{daemon_ipc} =
	    Forks::Super::Job::Ipc::_choose_fh_filename(
		'.daemon', purpose => 'daemon ipc');
	if ($Forks::Super::Debug::DEBUG) {
	    debug("Job will use ", $job->{daemon_ipc}, " to get daemon pid.");
	}
    }
    if ($job->{style} eq 'cmd' ||
	(&IS_WIN32 && $job->{style} eq 'exec')) {
	$job->{signal_ipc} =
	    Forks::Super::Job::Ipc::_choose_fh_filename(
		'.signal', purpose => 'signal ipc');
	if ($Forks::Super::Debug::DEBUG) {
	    debug("Job will use ", $job->{signal_ipc}, " to get signal pid.");
	}
    }
    return;
}

sub _preconfig_style {
  my $job = shift;

  ###################
  # set up style.
  #

  if (0 && defined $job->{run}) {   # not enabled
    $job->_preconfig_style_run;
  }

  if (defined $job->{cmd}) {
    if (ref $job->{cmd} ne 'ARRAY') {
      $job->{cmd} = [ $job->{cmd} ];
    }
    $job->{style} = 'cmd';
  } elsif (defined $job->{exec}) {
    if (ref $job->{exec} ne 'ARRAY') {
      $job->{exec} = [ $job->{exec} ];
    }
    $job->{style} = 'exec';
  } elsif (defined $job->{sub}) {
    $job->{style} = 'sub';
    $job->{sub} = qualify_sub_name $job->{sub};
    if (defined $job->{args}) {
      if (ref $job->{args} ne 'ARRAY') {
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

sub _preconfig_style_run {    ### for future use
  my $job = shift;
  if (ref $job->{run} ne 'ARRAY') {
    $job->{run} = [ $job->{run} ];
  }

  return;

  # How will we use or emulate the rich functionality
  # of IPC::Run?
  #
  # inputs are a "harness specification"
  # build a harness
  # on "launch", call $harness->start
  # when the job is reaped, call $harness->finish

  # one feature of IPC::Run harnesses is that they
  # may be reused!

}

sub _preconfig_dir {
    my $job = shift;
    if (defined $job->{chdir}) {
	$job->{dir} ||= $job->{chdir};
    }
    if (defined $job->{dir}) {
	$job->{dir} = Forks::Super::Util::abs_path($job->{dir});
    }
    return;
}

sub _preconfig_busy_action {
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

sub _preconfig_start_time {
  my $job = shift;

  ###########################
  # configure a future start time
  my $start_after = 0;
  if (defined $job->{delay}) {
    $start_after
      = Time::HiRes::time() 
	+ Forks::Super::Job::Timeout::_time_from_natural_language(
		$job->{delay}, 1);
  }
  if (defined $job->{start_after}) {
    my $start_after2 
      = Forks::Super::Job::Timeout::_time_from_natural_language(
		$job->{start_after}, 0);
    if ($start_after < $start_after2) {
      $start_after = $start_after2 
    }
  }
  if ($start_after) {
    $job->{start_after} = $start_after;
    delete $job->{delay};
    debug('_can_launch(): start delay requested.')
      if $job->{debug};
  }
  return;
}

sub _preconfig_dependencies {
  my $job = shift;

  ##########################
  # assert dependencies are expressed as array refs
  # expand job names to pids
  #
  if (defined $job->{depend_on}) {
    if (ref $job->{depend_on} ne 'ARRAY') {
      $job->{depend_on} = [ $job->{depend_on} ];
    }
    $job->{depend_on} = _resolve_names($job, $job->{depend_on});
  }
  if (defined $job->{depend_start}) {
    if (ref $job->{depend_start} ne 'ARRAY') {
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
    if (ref $id eq 'Forks::Super::Job') {
      push @out, $id;
    } elsif (is_number($id) && defined($ALL_JOBS{$id})) {
      push @out, $id;
    } else {
      my @j = Forks::Super::Job::getByName($id);
      if (@j > 0) {
	foreach my $j (@j) {
	  next if \$j eq \$job; 
	  # $j eq $job was not sufficient when $job is overloaded
	  # and $job->{pid} has not been set.

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
sub _config_parent {
  my $job = shift;
  $job->_config_fh_parent;
  $job->_config_timeout_parent;
  if ($Forks::Super::SysInfo::CONFIG{'getpgrp'}) {
    # when  timeout =>   or   expiration =>  is used,
    # PGID of child will be set to child PID
    if (defined($job->{timeout}) || defined($job->{expiration})) {
      $job->{pgid} = $job->{real_pid};
    } else {
      if (not eval { $job->{pgid} = getpgrp($job->{real_pid}) }) {
	$Forks::Super::SysInfo::CONFIG{'getpgrp'} = 0;
	$job->{pgid} = $job->{real_pid};
      }
    }
  }
  return;
}

sub _config_child {
  my $job = shift;
  $Forks::Super::Job::self = $job;
  $job->_config_env_child;
  $job->_config_callback_child;
  $job->_config_debug_child;
  $job->_config_timeout_child;
  $job->_config_os_child;
  $job->_config_fh_child;
  $job->_config_dir;
  return;
}

sub _config_env_child {
    my $job = shift;
    if ($job->{env} && ref($job->{env}) eq 'HASH') {
	foreach my $key (keys %{$job->{env}}) {
	    $ENV{$key} = $job->{env}{$key};
	}
    }
    return;
}

sub _config_debug_child {
  my $job = shift;
  if ($job->{debug} && $job->{undebug}) {
    if ($Forks::Super::Config::IS_TEST) {
      debug("Disabling debugging in child $$");
    }
    $Forks::Super::Debug::DEBUG = 0;
    $job->{debug} = 0;
  }
  return;
}

sub _config_dir {
  my $job = shift;
  $job->{dir} ||= $job->{chdir};
  if (defined $job->{dir}) {
      if (!chdir $job->{dir}) {
	  croak "Forks::Super::Job::launch(): ",
	  "Invalid \"dir\" option: \"$job->{dir}\" $!\n";
      }
  }
  return;
}

END {
    no warnings 'internal';
    $INSIDE_END_QUEUE = 1;
    if ($$ == ($Forks::Super::MAIN_PID ||= $$)) {

	# disable SIGCHLD handler during cleanup. Hopefully this will fix
	# intermittent test failures where all subtests pass but the
	# test exits with non-zero exit status (e.g., t/42d-filehandles.t)

	untie %SIG;
	unless (eval { delete $SIG{CHLD}; 1 }) {
	    $SIG{CHLD} = 'IGNORE';
	}

	Forks::Super::Queue::_cleanup();
	Forks::Super::Job::Ipc::_cleanup();
    } else {
	if (defined($Forks::Super::Job::self)
	    && defined($Forks::Super::Job::self->{_cleanup_code})) {
	    no strict 'refs';
	    $Forks::Super::Job::self->{_cleanup_code}->();
	}
	Forks::Super::Job::Timeout::_cleanup_child();
    }
}

#############################################################################
# Package methods (meant to be called as Forks::Super::Job::xxx(@args))

sub enable_overload {
  if (!$OVERLOAD_ENABLED) {
    $OVERLOAD_ENABLED = 1;

    if (!eval {
      use overload
	'""' => sub { $_[0]->{pid} },
	'+' => sub { $_[0]->{pid} + $_[1] },
        '*' => sub { $_[0]->{pid} * $_[1] },
        '&' => sub { $_[0]->{pid} & $_[1] },
        '|' => sub { $_[0]->{pid} | $_[1] },
        '^' => sub { $_[0]->{pid} ^ $_[1] },
        '~' => sub { ~$_[0]->{pid} },         # since 0.37
        '<=>' => sub { $_[2] ? $_[1] <=> $_[0]->{pid} 
			     : $_[0]->{pid} <=> $_[1] },
        'cmp' => sub { $_[2] ? $_[1] cmp $_[0]->{pid} 
			     : $_[0]->{pid} cmp $_[1] },
        '-'   => sub { $_[2] ? $_[1]  -  $_[0]->{pid} 
			     : $_[0]->{pid}  -  $_[1] },
        '/'   => sub { $_[2] ? $_[1]  /  $_[0]->{pid} 
			     : $_[0]->{pid}  /  $_[1] },
        '%'   => sub { $_[2] ? $_[1]  %  $_[0]->{pid} 
			     : $_[0]->{pid}  %  $_[1] },
        '**'  => sub { $_[2] ? $_[1]  ** $_[0]->{pid} 
			     : $_[0]->{pid}  ** $_[1] },
        '<<'  => sub { $_[2] ? $_[1]  << $_[0]->{pid} 
			     : $_[0]->{pid}  << $_[1] },
        '>>'  => sub { $_[2] ? $_[1]  >> $_[0]->{pid} 
			     : $_[0]->{pid}  >> $_[1] },
        'x'   => sub { $_[2] ? $_[1]  x  $_[0]->{pid} 
			     : $_[0]->{pid}  x  $_[1] },
        'cos'  => sub { cos $_[0]->{pid} },
        'sin'  => sub { sin $_[0]->{pid} },
        'exp'  => sub { exp $_[0]->{pid} },
        'log'  => sub { log $_[0]->{pid} },
        'sqrt' => sub { sqrt $_[0]->{pid} },
        'int'  => sub { int $_[0]->{pid} },
        'abs'  => sub { abs $_[0]->{pid} },
        'atan2' => sub { $_[2] ? atan2($_[1],$_[0]->{pid}) 
			       : atan2($_[0]->{pid},$_[1]) };

      # XXX - why doesn't it work when I include
      #       '<>' => sub { ... }
      #    in the  use overload  block?
      no strict 'refs';
      *{'Forks::Super::Job::(<>'} = sub {
	return $_[0]->read_stdout();
      };
      1 }            # end eval { use overload ... }
	) {
      carp "Error enabling overloading on Forks::Super::Job objects: $@\n";
    } elsif ($Forks::Super::Debug::DEBUG) {
        debug("Enabled overloading on Forks::Super::Job objects");
    }
  }
  return;
}

sub disable_overload {
  if ($OVERLOAD_ENABLED) {
    $OVERLOAD_ENABLED = 0;
    eval { no overload values %overload::ops; 1 }
        or Forks::Super::Debug::carp_once "Forks::Super::Job ",
    		"disable overload failed: $@";
  }
  return;
}

# returns a Forks::Super::Job object with the given identifier
sub get {
  my $id = shift;
  if (!defined $id) {
    Carp::cluck "undef value passed to Forks::Super::Job::get()";
  }
  if (ref $id eq 'Forks::Super::Job') {
    return $id;
  }
  if (defined $ALL_JOBS{$id}) {
    return $ALL_JOBS{$id};
  }
  return getByPid($id) || getByName($id);
}

sub getByPid {
  my $id = shift;
  if (is_number($id)) {
    my @j = grep { (defined($_->{pid}) && $_->{pid} == $id) ||
		   (defined($_->{real_pid}) && $_->{real_pid} == $id)
		 } @ALL_JOBS;
    return $j[0] if @j > 0;
  }
  return;
}

sub getByName {
  my $id = shift;
  my @j = grep { defined($_->{name}) && $_->{name} eq $id } @ALL_JOBS;
  if (@j > 0) {
    return wantarray ? @j : $j[0];
  }
  return;
}

# retrieve a job object for a pid or job name, if necessary
sub _resolve {
  if (ref $_[0] ne 'Forks::Super::Job') {
    my $job = get($_[0]);
    if (defined $job) {
      return $_[0] = $job;
    }
    return $job;
  }
  return $_[0];
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
  return scalar grep { defined($_->{state})
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
#    all alive jobs (ACTIVE+COMPLETE+SUSPENDED+DEFERRED+SUSPENDED-DEFERRED)
#    all active jobs (ACTIVE + COMPLETE + DEFERRED)
#    filtered alive jobs (by optional pgid)
#    filtered ACTIVE + COMPLETE + DEFERRED jobs
#
#    if  all_active==0  and  all_alive>0,  
#    then see Wait::WAIT_ACTION_ON_SUSPENDED_JOBS
#
sub count_processes {
  my ($count_bg, $optional_pgid) = @_;
  my @alive = grep { 
      $_->{state} ne 'REAPED' && 
	  $_->{state} ne 'NEW' &&
	  !$_->{daemon}
  } @ALL_JOBS;
  if (!$count_bg) {
    @alive = grep { $_->{_is_bg} == 0 } @alive;
  }
  my @active = grep { $_->{state} !~ /SUSPENDED/ } @alive;
  my @filtered_active = @active;
  my @filtered_alive = @alive;
  if (defined $optional_pgid) {
    @filtered_active = grep { $_->{pgid} == $optional_pgid } @filtered_active;
    @filtered_alive = grep { $_->{pgid} == $optional_pgid } @filtered_alive;
  }

  my @n = (scalar(@filtered_active), scalar(@alive), 
	   scalar(@active), scalar(@filtered_alive));

  if ($Forks::Super::Debug::DEBUG) {
    debug("count_processes(): @n");
    debug("count_processes(): Filtered active: ",
	  $filtered_active[0]->toString()) if $n[0];
    debug("count_processes(): Alive: ", $alive[0]->toShortString()) if $n[1];
    debug("count_processes(): Active: @active") if $n[2];
  }

  return @n;
}

sub init_child {
  Forks::Super::Job::Ipc::init_child();
  return;
}

sub deinit_child {
  Forks::Super::Job::Ipc::deinit_child();
  return;
}

#
# get the current CPU load. May not be possible
# to do on all operating systems.
#
sub get_cpu_load {
  return Forks::Super::Job::OS::get_cpu_load();
}

sub dispose {
  foreach my $job (@_) {

    my $pid = $job->{pid};
    my $real_pid = $job->{real_pid} || $pid;

    $job->close_fh('all');
    delete $Forks::Super::CHILD_STDIN{$pid};
    delete $Forks::Super::CHILD_STDIN{$real_pid};
    delete $Forks::Super::CHILD_STDOUT{$pid};
    delete $Forks::Super::CHILD_STDOUT{$real_pid};
    delete $Forks::Super::CHILD_STDERR{$pid};
    delete $Forks::Super::CHILD_STDERR{$real_pid};

    foreach my $attr ('f_in','f_out','f_err') {
      my $file = $job->{fh_config} && $job->{fh_config}->{$attr};
      if (defined($file) && -f $file) {
	$! = 0;
	if (unlink $file) {
	  delete $Forks::Super::Job::Ipc::IPC_FILES{$file};
	} elsif ($INSIDE_END_QUEUE) {
	  warn "unlink failed for \"$file\": $! $^E\n";
	  warn "@{$Forks::Super::Job::Ipc::IPC_FILES{$file}}\n";
	}
      }
    }

    # XXX - disposed jobs should go to %ARCHIVED_JOBS, @ARCHIVED_JOBS
    my @k = grep { $ALL_JOBS{$_} eq $job } keys %ALL_JOBS;
    delete $ALL_JOBS{$_} for @k;

    delete $job->{$_} for keys %$job;
    $job->{disposed} ||= time;
  }
  @ALL_JOBS = grep { !$_->{disposed} } @ALL_JOBS;
  return;
}

#
# Print information about all known jobs to currently selected filehandle.
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

sub get_win32_proc { return $WIN32_PROC; }
sub get_win32_proc_pid { return $WIN32_PROC_PID; }

1;

__END__

=head1 NAME

Forks::Super::Job - object representing a background task

=head1 VERSION

0.53

=head1 SYNOPSIS

    use Forks::Super;

    $pid = Forks::Super::fork( \%options );  # see Forks::Super
    $job = Forks::Super::Job::get($pid);
    $job = Forks::Super::Job::getByName($name);

    print "Current job state is $job->{state}\n";
    print "Job was created at ", scalar localtime($job->{created}), "\n";

=head2 with overloading

See L</"OVERLOADING">.

    use Forks::Super 'overload';
    $job = Forks::Super::fork( \%options );
    print "Process id of new job is $job\n";
    print "Current state is ", $job->state, "\n";
    waitpid $job, 0;
    print "Exit status was ", $job->status, "\n";

=head1 DESCRIPTION

Calls to C<Forks::Super::fork()> that successfully spawn a child process or
create a deferred job (see L<Forks::Super/"Deferred processes">) will cause 
a C<Forks::Super::Job> instance to be created to track the job's state. 
For many uses of C<fork()>, it will not be necessary to query the state of 
a background job. But access to these objects is provided for users who 
want to exercise even greater control over their use of background
processes.

Calls to C<Forks::Super::fork()> that fail (return C<undef> or small negative
numbers) generally do not cause a new C<Forks::Super::Job> instance
to be created.

=head1 ATTRIBUTES

Use the C<Forks::Super::Job::get> or C<Forks::Super::Job::getByName>
methods to obtain a Forks::Super::Job object for
examination. The C<Forks::Super::Job::get> method takes a process ID or
job ID as an input (a value that may have been returned from a previous
call to C<Forks::Super::fork()> and returns a reference to a 
C<Forks::Super::Job> object, or C<undef> if the process ID or job ID 
was not associated with any known Job object. The 
C<Forks::Super::Job::getByName> looks up job objects by the 
C<name> parameter that may have been passed
in the C<Forks::Super::fork()> call.

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
L<getpgrp|perlfunc/"getpgrp">.

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

For jobs that have started in a child process and are,
to the knowledge of the parent process, still running.

=item C<COMPLETE>

For jobs that have completed and caused the parent process to
receive a C<SIGCHLD> signal, but have not been reaped.

The difference between a C<COMPLETE> job and a C<REAPED> job
is whether the job's process identifier has been returned in
a call to C<Forks::Super::wait> or C<Forks::Super::waitpid>
(or implicitly returned in a call to C<Forks::Super::waitall>).
When the process gets reaped, the global variable C<$?>
(see L<perlvar/"$CHILD_ERROR">) will contain the exit status
of the process, until the next time a process is reaped.

=item C<REAPED>

For jobs that have been reaped by a call to C<Forks::Super::wait>,
C<Forks::Super::waitpid>, or C<Forks::Super::waitall>.

=item C<SUSPENDED>

The job has started but it has been suspended (with a C<SIGSTOP>
or other appropriate mechanism for your operating system) and
is not currently running. A suspended job will not consume CPU
resources but my tie up memory resources.

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

=item child_stdin

=item child_stdout

=item child_stderr

If the job has been configured for interprocess communication,
these attributes correspond to the handles for passing
standard input to the child process, and reading standard 
output and standard error from the child process, respectively.

Note that the standard read/write operations on these filehandles
can also be accomplished through the C<write_stdin>, C<read_stdout>,
and C<read_stderr> methods of this class. Since these methods
can adjust their behavior based on the type of IPC channel
(file, socket, or pipe) or other idiosyncracies of your operating
system (#@$%^&*! Windows), B<using these methods is preferred
to using the filehandles directly>.

=back

=cut

=head1 FUNCTIONS

=head3 get

=over 4

=item C< $job = Forks::Super::Job::get($pidOrName) >

Looks up a C<Forks::Super::Job> object by a process ID/job ID
or L<name|Forks::Super/"name"> attribute and returns the
job object. Returns C<undef> for an unrecognized pid or
job name.

=back

=head3 count_active_processes

=over 4

=item C< $n = Forks::Super::Job::count_active_processes() >

Returns the current number of active background processes.
This includes only

=over 4

=item 1. First generation processes. Not the children and
grandchildren of child processes.

=item 2. Processes spawned by the C<Forks::Super> module,
and not processes that may have been created outside the
C<Forks::Super> framework, say, by an explicit call to
C<CORE::fork()>, a call like C<system("./myTask.sh &")>,
or a form of Perl's C<open> function that launches an
external command.

=back

=back

=head1 METHODS

A C<Forks::Super::Job> object recognizes the following methods.
In general, these methods should only be used from the foreground
process (the process that spawned the background job).

=head3 waitpid

=over 4

=item C<< $job->wait( [$timeout] ) >>

=item C<< $job->waitpid( $flags [,$timeout] ) >>

Convenience method to wait until or test whether the specified
job has completed. See L<Forks::Super::waitpid|Forks::Super/"waitpid">.

The calls C<< $job->wait >> and C<< $job->wait() >> will block until a 
job has completed. But C<< $job->wait(0) >> will call C<wait> with
a timeout of zero seconds, so it will be equivalent to a call of
C<< waitpid $job, &WNOHANG >>.

=back

=head3 kill

=over 4

=item C<< $job->kill($signal) >>

Convenience method to send a signal to a background job.
See L<Forks::Super::kill|Forks::Super/"kill">.

=back

=head3 suspend

=over 4

=item C<< $job->suspend >>

When called on an active job, suspends the background process with 
C<SIGSTOP> or other mechanism appropriate for the operating system.

=back

=head3 resume

=over 4

=item C<< $job->resume >>

When called on a suspended job (see L<< suspend|"$job->suspend" >>,
above), resumes the background process with C<SIGCONT> or other mechanism 
appropriate for the operating system.

=back

=head3 is_E<lt>stateE<gt>

=over 4

=item C<< $job->is_complete >>

Indicates whether the job is in the C<COMPLETE> or C<REAPED> state.
This method may not return accurate results for L<daemon|Forks::Super/daemon>
processes.

=item C<< $job->is_started >>

Indicates whether the job has started in a background process.
While return a false value while the job is still in a deferred state.
This method may not return accurate results for L<daemon|Forks::Super/daemon>
processes.

=item C<< $job->is_active >>

Indicates whether the specified job is currently running in
a background process.
This method may not return accurate results for L<daemon|Forks::Super/daemon>
processes.

=item C<< $job->is_suspended >>

Indicates whether the specified job has started but is currently
in a suspended state.
This method may not return accurate results for L<daemon|Forks::Super/daemon>
processes.

=back

=head3 write_stdin

=over 4

=item C<< $job->write_stdin(@msg) >>

Writes the specified message to the child process's standard input
stream, if the child process has been configured to receive
input from interprocess communication. Writing to a closed 
handle or writing to a process that is not configured for IPC
will result in a warning.

Using this method may be preferrable to calling C<print> with the
process's C<child_stdin> attribute, as the C<write_stdin> method
will take into account the type of IPC channel (file, socket, or
pipe) and may alter its behavior because of it. In a near future
release, it is hoped that the simple C<print> to the child stdin
filehandle will do the right thing, using tied filehandles and
other Perl magic.

=back

=head3 read_stdout

=head3 read_stderr

=over 4

=item C<< $line = $job->read_stdout() >>

=item C<< @lines = $job->read_stdout() >>

=item C<< $line = $job->read_stderr() >>

=item C<< @lines = $job->read_stderr() >>

In scalar context, attempts to read a single line, and in list
context, attempts to read all available lines from a child
process's standard output or standard error stream. 

If there is no available input, and if the C<Forks::Super> module
detects that the background job has completed (such that no more
input will be created), then the file handle will automatically be
closed. In scalar context, these methods will return C<undef>
if there is no input currently available on an inactive process,
and C<""> (empty string) if there is no input available on
an active process.

Reading from a closed handle, or calling these methods on a
process that has not been configured for IPC will result in
a warning.

=back

=head3 close_fh

=over 4

=item C<< $job->close_fh([@handle_id]) >>

Closes IPC filehandles for the specified job. Optional input
is one or more values from the set C<stdin>, C<stdout>, C<stderr>,
and C<all> to specify which filehandles to close. If no
parameters are provided, the default behavior is to close all
configured file handles.

The C<close_fh> method may perform certain cleanup operations
that are specific to the type and settings of the specified
handle, so using this method is preferred to:

    # not as good as:  $job->close_fh('stdin','stderr')
    close $job->{child_stdin};
    close $Forks::Super::CHILD_STDERR{$job};

On most systems, open filehandles are a scarce resource and it
is a very good practice to close filehandles when the jobs that
created them are finished running and you are finished processing
input and output on those filehandles.

=back

=head3 state

=over 4

=item C<< $state = $job->state >>

Method to access the job's current state. See L</ATTRIBUTES>.

=back

=head3 status, exit_status

=over 4

=item C<< $status = $job->status >>

=item C<< $short_status = $job->exit_status >>

=item C<< ($exit_code,$signal,$coredump) = $job->exit_status >>

For completed jobs, the C<<status>> method returns the job's
exit status. See L</ATTRIBUTES>.

C<<exit_status>> is a convenience method for retrieving the
more intuitive exit value of a background task.

In scalar context,
it returns the exit status of the program (as returned by the
L<wait|perlfunc/wait> call), but I<shifted right by eight bits>,
so that a program that ends by calling C<exit(7)> will have an
C<exit_status> of 7, not 7 * 256. If the background process
exited on a signal and/or with a core dump, the result of this
function is a negative number that indicates the signal that
caused the background process failure.

In list context, C<<exit_status>> returns a three element array
of the exit value, the signal number, and an indicator of
whether the process dumped core.

C<<exit_status>> returns nothing if called on a job that has
not completed.

=back

=head3 toString

=over 4

=item C<< $job->toString() >>

=item C<< $job->toShortString() >>

Outputs a string description of the important features of the job.

=back

=head3 reuse

=over 4

=item C<< $pid = $job->reuse( \%new_opts ) >>

Creates a new background process by calling C<Forks::Super::fork>,
using all of the existing settings of the current C<Forks::Super::Job>
object. Additional options may be provided which will override
the original settings.

Use this method to launch multiple instances of identical or
similar jobs.

    $job = fork { child_fh => "all",
              callback => { start => sub { print "I started!" },
                            finish => sub { print "I finished!" } },
              sub => sub {
                 do_something();
                 do_something_else();
                 ...   # do 100 other things.
              },
              args => [ @the_args ], timeout => 15
    };

    # Crikey, I'm not typing all that in again.
    $job2 = $job->reuse { args => [ @new_args ], timeout => 30 };

=back

=head3 dispose

=over 4

=item C<< $job->dispose() >>

=item C<< Forks::Super::Job::dispose( @jobs ) >>

Called on one or more job objects to free up any resources used
by a job object. You may call this method on any job where you 
have finished extracting all of the information that you need
from the job. Or to put it another way, you should not call this
method on a job if you still wish to access any information 
about the job. After this method is invoked on a job, any
information such as run times, status, and unread input from 
interprocess communication handles will be lost.

This method will

=over 4

=item * close any open filehandles

=item * attempt to remove temporary files used for interprocess communication ]with the job

=item * erase all information about the job

=item * remove the job object from the C<@ALL_JOBS> and C<%ALL_JOBS> variables.

=back

=back

=head1 VARIABLES

=head2 @ALL_JOBS, %ALL_JOBS

Any job object created by this module will be added to the list
C<@Forks::Super::Job::ALL_JOBS> and to the lookup table
C<%Forks::Super::Job::ALL_JOBS>. Within C<%ALL_JOBS>, a specific
job object can be accessed by its job id (the numerical value returned
from C<Forks::Super::fork()>), its real process id (once the
job has started), or its C<name> attribute, if one was passed to
the C<Forks::Super::fork()> call. This may be helpful for iterating
through all of the jobs your program has created.

    my ($longest_job, $longest_time) = (-1, -1);
    foreach $job (@Forks::Super::ALL_JOBS) {
        if ($job->is_complete) {
            $job_time = $job->{end} - $job->{start};
            if ($job_time > $longest_time) {
                ($longest_job, $longest_time) = ($job, $job_time);
            }
        }
    }
    print STDERR "The job that took the longest was $job: ${job_time}s\n";

Jobs that have been passed to the L<"dispose"> method are removed
from C<@ALL_JOBS> and C<%ALL_JOBS>.

=head1 OVERLOADING

An available feature in the L<Forks::Super> module is to make
it more convenient to access the functionality of 
C<Forks::Super::Job>. When this feature is enabled, the 
return value from a call to C<Forks::Super::fork()> is an
I<overloaded> C<Forks::Super::Job> object. 

    $job_or_pid = fork { %options };

In a numerical context, this value looks and behaves like
a process ID (or job ID). The value can be passed to functions
like C<kill> and C<waitpid> that expect a process ID.

    if ($job_or_pid != $another_pid) { ... }
    kill 'TERM', $job_or_pid;

But you can also access the attributes and methods of the
C<Forks::Super::Job> object.

    $job_or_pid->{real_pid}
    $job_or_pid->suspend

Since v0.51, the C<< <> >> iteration operator has been overloaded
for the C<Forks::Super::Job> package. It can be used to read
one line of output from a background job's standard output,
and to allow you to treat the background job object
syntactically like a readable filehandle.

    my $job = fork { cmd => $command };
    while (<$job>) {
        print "Output from $job: $_\n";
    }

Since v0.41, this feature is enabled by default.

Whether the overloading is enabled by default or not, you can
override the default behavior in three ways:

=over 4

=item 1. Set the environment variable C<FORKS_SUPER_JOB_OVERLOAD>
to a true or false value

    $ FORKS_SUPER_JOB_OVERLOAD=0 perl a_script_that_uses_Forks_Super.pl ...

=item 2. Pass the parameter C<< overload >> to the module import function
with a C<0> or C<1> value

    use Forks::Super overload => 1;  # always enable overload feature

=item 3. At runtime, call

    Forks::Super::Job::enable_overload();
    Forks::Super::Job::disable_overload();

In principle you may call these methods at any time and as often 
as you wish.

=back

Even when overloading is enabled, C<Forks::Super::fork()> 
still returns a simple scalar value of 0 to the child process
(when a value is returned).

=head1 SEE ALSO

L<Forks::Super>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2011, Marty O'Brien.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

See http://dev.perl.org/licenses/ for more information.

=cut
