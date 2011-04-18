package Forks::Super;

#                 "safe" signals ($] >= 5.7.3) are strongly recommended ...
# use 5.007003;   ... but no longer required



use Forks::Super::SysInfo;
use Forks::Super::Job;
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(:all);
use Forks::Super::Config qw(:all);
use Forks::Super::Queue qw(:all);
use Forks::Super::Wait qw(:all);
use Forks::Super::Tie::Enum;
use Forks::Super::Sigchld;
use Forks::Super::LazyEval;
use Signals::XSIG;   # replaces Forks::Super::Sighandler
use strict;
use warnings;

use Exporter;
our @ISA = qw(Exporter);
#use base 'Exporter';

use POSIX ':sys_wait_h';
use Carp;
$Carp::Internal{ (__PACKAGE__) }++;
$| = 1;

our @EXPORT = qw(fork wait waitall waitpid);
my @export_ok_func = qw(isValidPid pause Time read_stdout read_stderr
			bg_eval bg_qx open2 open3);
my @export_ok_vars = qw(%CHILD_STDOUT %CHILD_STDERR %CHILD_STDIN);
our @EXPORT_OK = (@export_ok_func, @export_ok_vars);
our %EXPORT_TAGS = 
  ( 'test'        => [ qw(isValidPid Time bg_eval bg_qx), @EXPORT ],
    'test_config' => [ qw(isValidPid Time bg_eval bg_qx), @EXPORT ],
    'test_CA'     => [ qw(isValidPid Time bg_eval bg_qx), @EXPORT ],
    'filehandles' => [ @export_ok_vars, @EXPORT ],
    'vars'        => [ @export_ok_vars, @EXPORT ],
    'all'         => [ @EXPORT_OK, @EXPORT ] );
our $VERSION = '0.51';

our $SOCKET_READ_TIMEOUT = 1.0;
our ($MAIN_PID, $ON_BUSY, $MAX_PROC, $MAX_LOAD, $DEFAULT_MAX_PROC, $IPC_DIR);
our ($DONT_CLEANUP, $CHILD_FORK_OK, $QUEUE_INTERRUPT, $PKG_INITIALIZED);
our (%IMPORT, $LAST_JOB, $LAST_JOB_ID, %BASTARD_DATA);
push @Devel::DumpTrace::EXCLUDE_PATTERN, '^Signals::XSIG';

sub import {
  my ($class,@args) = @_;
  my @tags;
  _init();
  my $ipc_dir = '';
  my $cleanse_requested = 0;
  for (my $i=0; $i<@args; $i++) {
    if ($args[$i] eq 'MAX_PROC') {
      $MAX_PROC = $args[++$i];
    } elsif ($args[$i] eq 'MAX_LOAD') {
      $MAX_LOAD = $args[++$i];
    } elsif ($args[$i] eq 'DEBUG') {
      $DEBUG = $args[++$i];
    } elsif ($args[$i] eq 'ON_BUSY') {
      $ON_BUSY = $args[++$i];
    } elsif ($args[$i] eq 'CHILD_FORK_OK') {
      $CHILD_FORK_OK = $args[++$i];
    } elsif ($args[$i] eq 'QUEUE_MONITOR_FREQ') {
      $Forks::Super::Queue::QUEUE_MONITOR_FREQ = $args[++$i];
    } elsif ($args[$i] eq 'QUEUE_INTERRUPT') {
      $QUEUE_INTERRUPT = $args[++$i];
    } elsif ($args[$i] eq 'FH_DIR' || $args[$i] eq 'IPC_DIR') {
      $ipc_dir = $args[++$i];
    } elsif (uc $args[$i] eq 'OVERLOAD') {
      if ($i+1 < @args && $args[$i+1] =~ /^\d+$/) {
	if ($args[++$i] == 0) {
	  Forks::Super::Job::disable_overload();
	} else {
	  Forks::Super::Job::enable_overload();
	}
      } else {
	  Forks::Super::Job::enable_overload();
      }
    } elsif (uc $args[$i] eq 'CLEANSE') {
      $cleanse_requested++;
      if ($i+1 < @args) {
	$ipc_dir = $args[++$i] || '';
      }
      $Forks::Super::Job::Ipc::_CLEANSE_MODE = 1;
    } else {
      push @tags, $args[$i];
      if ($args[$i] =~ /^:test/) {
	no warnings;
	*Forks::Super::Job::carp = *Forks::Super::carp
	  = *Forks::Super::Job::Timeout::carp
	  = *Forks::Super::Job::Ipc::carp
	  = *Forks::Super::Tie::Enum::carp = sub { warn @_ };
	$Forks::Super::Config::IS_TEST = 1;
	if ($args[$i] =~ /config/) {
	  $Forks::Super::Config::IS_TEST_CONFIG = 1
	}

	# preload some modules so lazy loading doesn't affect
	# the timing in some unit tests
	### Forks::Super::Job::Timeout::warm_up();

	if ($args[$i] =~ /CA/) {
	  Forks::Super::Debug::_use_Carp_Always();
	}
      }
    }
  }
  if ($ENV{FH_DIR} || $ENV{IPC_DIR} || $ipc_dir) {
    # deprecated warning if  FH_DIR  is set but not  IPC_DIR
    if ($ENV{FH_DIR} && !$ENV{IPC_DIR}) {
      carp "Environment variable 'FH_DIR' is deprecated. Use 'IPC_DIR'\n";
    }
    Forks::Super::Job::Ipc::set_ipc_dir($ENV{IPC_DIR}, 1)
	|| Forks::Super::Job::Ipc::set_ipc_dir($ENV{FH_DIR}, 1)
	|| Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir, 1);
  }

  $IMPORT{$_}++ foreach @tags;
  Forks::Super->export_to_level(1, "Forks::Super", @tags?@tags:@EXPORT);

  if ($cleanse_requested) {
    Forks::Super::Job::Ipc::cleanse($ipc_dir || $IPC_DIR);
    exit;
  }
  return;
}

sub _init {
  return if $PKG_INITIALIZED;
  $PKG_INITIALIZED++;

  Forks::Super::Debug::init();
  Forks::Super::Config::init();

  # $Forks::Super::SysInfo::MAX_FORK is the point at which your program
  # might crash from having too many forks.
  #
  # Another reasonable default when there are moderately CPU-intensive
  # background tasks is  ~2*$Forks::Super::SysInfo::NUM_PROCESSORS.

  # Default value for $MAX_PROC should be tied to system properties
  $DEFAULT_MAX_PROC = $Forks::Super::SysInfo::MAX_FORK - 1;

  $MAX_PROC = $DEFAULT_MAX_PROC;
  $MAX_LOAD = -1;

  # OK for child process to call Forks::Super::fork()? That could be a bad idea
  $CHILD_FORK_OK = 0;

  # Disable cleanup of IPC files? Sometimes helpful for debugging.
  $DONT_CLEANUP = $ENV{FORKS_DONT_CLEANUP} || 0;

  # choose of $Forks::Super::Util::DEFAULT_PAUSE is a tradeoff between
  # accuracy/responsiveness and performance.
  # Low values will make pause/waitpid calls very busy, consuming cpu cycles
  # High values increases the delay between one job finishing and a queued
  # job starting, or decreases the accuracy of timed features (e.g., the
  # job that is supposed to timeout after 2s times out after 3s)
  $Forks::Super::Util::DEFAULT_PAUSE = 0.10;

  *handle_CHLD = *Forks::Super::Sigchld::handle_CHLD;

  Forks::Super::Util::set_productive_pause_code {
    Forks::Super::Queue::check_queue() if !$Forks::Super::Queue::_LOCK;
    handle_CHLD(-1);
  };

  Forks::Super::Wait::set_productive_waitpid_code {
    if (&IS_WIN32) {
      handle_CHLD(-1);
    }
  };

  tie $ON_BUSY, 'Forks::Super::Tie::Enum', qw(block fail queue);
  $ON_BUSY = 'block';

  tie $IPC_DIR, 'Forks::Super::Job::Ipc::Tie';

  Forks::Super::Queue::init();

  $XSIG{CHLD}[-1] = \&Forks::Super::Sigchld::handle_CHLD;
  return;
}

sub fork {
  my ($opts) = @_;
  if (ref $opts ne 'HASH') {
    $opts = { @_ };
  }

  $MAIN_PID ||= $$;                         # initialize on first use 
  my $job = Forks::Super::Job->new($opts);
  $job->_preconfig;
  if (defined $job->{__test}) {
    return $job->{__test};
  }

  debug('fork(): ', $job->toString(), ' initialized.')
    if $job->{debug};

  until ($job->can_launch) {

    debug("fork(): job can not launch. Behavior=$job->{_on_busy}")
      if $job->{debug};

    if ($job->{_on_busy} eq 'FAIL') {
      $job->run_callback('fail');

      #$job->_mark_complete;
      $job->{end} = Time::HiRes::time();

      $job->{status} = -1;
      $job->_mark_reaped;
      return -1;
    } elsif ($job->{_on_busy} eq 'QUEUE') {
      $job->run_callback('queue');
      $job->queue_job;
      if ($Forks::Super::Job::OVERLOAD_ENABLED) {
	return $job;
      } else {
	return $job->{pid};
      }
    } else {
      pause();
    }
  }

  if ($job->{debug}) {
    debug('Forks::Super::fork(): launch approved for job');
  }
  return $job->launch;
}

# called from a child process immediately after it
# is created. Mostly this subroutine is about DE-initializing
# the child; removing all the global state that only the
# parent process needs to know about.
sub init_child {
  if ($$ == $MAIN_PID) {
    carp "Forks::Super::init_child() ",
      "method called from main process!\n";
    return;
  }
  Forks::Super::Queue::init_child();

  @ALL_JOBS = ();

  # XXX - if $F::S::CHILD_FORK_OK > 0, when do we reset $XSIG{CHLD} ?
  $XSIG{CHLD} = [];
  $SIG{CHLD} = 'DEFAULT';
  #$XSIG{CLD} = [];
  #$SIG{CLD} = 'DEFAULT';

  Forks::Super::Config::init_child();
  Forks::Super::Job::init_child();
  return;
}

#
# returns the exit status of the given process ID or job ID.
# return undef if we don't think the process is complete yet.
#
sub status {
  my $job = shift;
  if (ref $job ne 'Forks::Super::Job') {
    $job = Forks::Super::Job::get($job) || return;
  }
  return $job->{status}; # might be undef
}

sub state {
  my $job = shift;
  if (ref $job ne 'Forks::Super::Job') {
    $job = Forks::Super::Job::get($job) || return;
  }
  return $job->{state};
}

sub write_stdin {
  my ($job, @msg) = @_;
  return Forks::Super::Job::write_stdin($job, @msg);
}

#
# called from the parent process,
# attempts to read a line from standard output filehandle
# of the specified child.
#
# returns "" if the process is running but there is no
# output waiting on the filehandle
#
# returns undef if the process has completed and there is
# no output waiting on the filehandle
#
# performs trivial seek on filehandle before reading.
# this will reduce performance but will always clear
# error condition and eof condition on handle
#
sub read_stdout {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  return Forks::Super::Job::read_stdout(@_);
}

#
# like read_stdout() but for stderr.
#
sub read_stderr {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  return Forks::Super::Job::read_stderr(@_);
}

sub close_fh {
  my $pid_or_job = shift;
  if (Forks::Super::Job::_resolve($pid_or_job)) {
    $pid_or_job->close_fh(@_);
  } elsif ($pid_or_job) {
    carp "Forks::Super::close_fh: ",
      "input $pid_or_job is not a recognized identifier of a background job\n";
  } else {
    carp "Forks::Super::close_fh: invalid empty input  $pid_or_job\n";
  }
}

######################################################################

sub kill_all {
  my ($signal) = @_;
  my @all_jobs;
  if ($signal eq 'CONT') {
    @all_jobs = grep { $_->is_suspended } @Forks::Super::ALL_JOBS;
  } elsif ($signal eq 'STOP') {
    @all_jobs = grep { $_->is_active || $_->{state} eq 'DEFERRED' }
      @Forks::Super::ALL_JOBS;
  } else {
    @all_jobs = grep { $_->is_active } @Forks::Super::ALL_JOBS;
  }
  Forks::Super::kill $signal, @all_jobs;
}

sub kill {
  my ($signal, @jobs) = @_;
  my $kill_proc_group = $signal =~ s/^-//;
  my $num_signalled = 0;
  my $run_queue_needed = 0;

  # convert to canonical signal name.
  $signal = Forks::Super::Util::signal_name($signal);
  if ($signal eq '') {
    carp "Forks::Super::kill: invalid signal spec $_[0]\n";
    return 0;
  }

  @jobs = map { ref $_ eq 'Forks::Super::Job' 
		  ? $_ : Forks::Super::Job::get($_) } @jobs;
  @jobs = grep { !$_->is_complete
		   && $_->{state} ne 'NEW'
		   && $_->{state} ne 'LAUNCHING' } @jobs;

  my @deferred_jobs = grep { $_->is_deferred } @jobs;
  if (@deferred_jobs > 0) {
    my @sdj_result = _signal_deferred_jobs($signal, @deferred_jobs);
    $num_signalled += $sdj_result[0];
    $run_queue_needed += $sdj_result[1];
    @jobs = grep { ! $_->is_deferred } @jobs;
    if (@jobs == 0) {
      return $num_signalled;
    }
  }

  my @pids = map { $_->{real_pid} } @jobs;
  if ($DEBUG) {
    debug("Sending signal $signal to pids: ", join(' ',@pids));
  }
  my @terminated = ();

  if (&IS_WIN32) {

    # preferred way to kill a MSWin32 pseudo-process
    # is with the Win32 API "TerminateThread". Using Perl's kill
    # usually doesn't work

    my ($signalled, $termref)
      = Forks::Super::Job::OS::Win32::signal_procs(
			$signal, $kill_proc_group, @pids);
    $num_signalled += $signalled;
    push @terminated, @$termref;

  } elsif (@pids > 0) {
    if (Forks::Super::Util::is_kill_signal($signal)) {
      foreach my $pid (@pids) {
	local $! = 0;
	if (CORE::kill $signal, $pid) {
	  $num_signalled++;
	  push @terminated, $pid;
	}
	if ($!) {
	  carp "kill error $! $^E\n";
	}
      }
    } else {
      local $! = 0;
      $num_signalled += CORE::kill $signal, @pids;
      if ($!) {
	carp "kill error $! $^E\n";
      }
    }
  }

  _unreap(@terminated);
  $run_queue_needed && Forks::Super::Queue::check_queue();
  return $num_signalled;
}

sub _signal_deferred_jobs {
  my ($signal, @jobs) = @_;
  my $num_signalled = 0;
  my $run_queue_needed = 0;
  foreach my $j (@jobs) {
    if (Forks::Super::Util::is_kill_signal($signal)) {
      $j->_mark_complete;
      $j->{status} = Forks::Super::Util::signal_number($signal) || -1;
      $j->_mark_reaped;
      $num_signalled++;
    } elsif ($signal eq 'STOP') {
      $j->{state} = 'SUSPENDED-DEFERRED';
      $num_signalled++;
    } elsif ($signal eq 'CONT') {
      $j->{state} = 'DEFERRED';
      $run_queue_needed++;
      $num_signalled++;
    } elsif ($signal eq 'ZERO') {
      $num_signalled++;
    } else {
      carp_once [$signal], "Received signal '$signal' on deferred job(s),",
	" Ignoring.\n";
    }
  }
  return ($num_signalled, $run_queue_needed);
}

sub _unreap {
  my (@pids) = @_;
  my $old_status = $?;
  foreach my $pid (@pids) {
    if ($pid == waitpid $pid, 0, 1.0) {
      my $j = Forks::Super::Job::get($pid);
      $j->{state} = 'COMPLETE';
      delete $j->{reaped};
      $? = $old_status;
    }
  }
}

#############################################################################

# convenience methods

sub open2 {
  my (@cmd) = @_;
  my $options = {};
  if (ref $cmd[-1] eq 'HASH') {
    $options = pop @cmd;
  }
  $options->{'cmd'} = @cmd > 1 ? \@cmd : $cmd[0];
  $options->{'child_fh'} = "in,out";

  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    if (defined($options->{'timeout'}) || defined($options->{'expiration'})) {
      croak "Forks::Super::open2: ",
	"can't use timeout/expiration option because sleep/alarm ",
	"are incompatible on this system\n";
    }
  }

  my $pid = Forks::Super::fork( $options );
  if (!defined $pid) {
    return;
  }
  my $job = Forks::Super::Job::get($pid);

  return ($job->{child_stdin},
	  $job->{child_stdout},
	  $pid, $job);
}

sub open3 {
  my (@cmd) = @_;
  my $options = {};
  if (ref $cmd[-1] eq 'HASH') {
    $options = pop @cmd;
  }
  $options->{'cmd'} = @cmd > 1 ? \@cmd : $cmd[0];
  $options->{'child_fh'} = "in,out,err";

  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    if (defined($options->{'timeout'}) || defined($options->{'expiration'})) {
      croak "Forks::Super::open2: ",
	"can't use timeout/expiration option because sleep/alarm ",
	"are incompatible on this system\n";
    }
  }

  my $pid = Forks::Super::fork( $options );
  if (!defined $pid) {
    return;
  }
  my $input = $Forks::Super::CHILD_STDIN{$pid};
  my $output = $Forks::Super::CHILD_STDOUT{$pid};
  my $error = $Forks::Super::CHILD_STDERR{$pid};
  my $job = Forks::Super::Job::get($pid);
  return ($job->{child_stdin},
	  $job->{child_stdout},
	  $job->{child_stderr},
	  $pid, $job);
}


#############################################################################

sub _you_bastard {
  my ($pid, $status) = @_;
  $BASTARD_DATA{$pid} = [ scalar Time::HiRes::time(), $status ];
  return;
}

sub _set_last_job {
  my ($job, $id) = @_;
  $LAST_JOB = $job;
  $LAST_JOB_ID = ref $id eq 'Forks::Super::Job' ? $id->{pid} : $id;
  return;
}

sub _is_test {
  return defined($IMPORT{':test'}) && $IMPORT{':test'};
}

###################################################################

1;

__END__

------------------------------------------------------------------------------

=head1 NAME

Forks::Super - extensions and convenience methods to manage background processes.

=head1 VERSION

Version 0.51

=head1 SYNOPSIS

    use Forks::Super;
    use Forks::Super MAX_PROC => 5, DEBUG => 1;

    # familiar use - parent returns PID>0, child returns zero
    $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid > 0) {
        # parent code
    } else {
        # child code
    }

    # wait for a child process to finish
    $w = wait;                  # blocking wait on any child, $? holds child exit status
    $w = waitpid $pid, 0;       # blocking wait on specific child
    $w = waitpid $pid, WNOHANG; # non-blocking wait, use with POSIX ':sys_wait_h'
    $w = waitpid 0, $flag;      # wait on any process in current process group
    waitall;                    # block until all children are finished

    # -------------- helpful extensions ---------------------
    # fork directly to a shell command. Child doesn't return.
    $pid = fork { cmd => "./myScript 17 24 $n" };
    $pid = fork { exec => [ "/bin/prog" , $file, "-x", 13 ] };

    # fork directly to a Perl subroutine. Child doesn't return.
    $pid = fork { sub => $methodNameOrRef , args => [ @methodArguments ] };
    $pid = fork { sub => \&subroutine, args => [ @args ] };
    $pid = fork { sub => sub { "anonymous sub" }, args => [ @args ] );

    # put a time limit on the child process
    $pid = fork { cmd => $command, 
                  timeout => 30 };            # kill child if not done in 30s
    $pid = fork { sub => $subRef , args => [ @args ],
                  expiration => 1260000000 }; # complete by 8AM Dec 5, 2009 UTC

    # run a child process starting from a different directory
    $pid = fork { dir => "some/other/directory",
                  cmd => ["command", "--that", "--runs=somewhere", "else"] };

    # obtain standard filehandles for the child process
    $pid = fork { child_fh => "in,out,err" };
    if ($pid == 0) {      # child process
      sleep 1;
      $x = <STDIN>; # read from parent's $Forks::Super::CHILD_STDIN{$pid}
      print rand() > 0.5 ? "Yes\n" : "No\n" if $x eq "Clean your room\n";
      sleep 2;
      $i_can_haz_ice_cream = <STDIN>;
      if ($i_can_haz_ice_cream !~ /you can have ice cream/ && rand() < 0.5) {
          print STDERR '@#$&#$*&#$*&',"\n";
      }
      exit 0;
    } # else parent process
    $child_stdin = $Forks::Super::CHILD_STDIN{$pid};
    print $child_stdin "Clean your room\n";
    sleep 2;
    $child_stdout = $Forks::Super::CHILD_STDOUT{$pid};
    $child_response = <$child_stdout>; # -or-: Forks::Super::read_stdout($pid);
    if ($child_response eq "Yes\n") {
        print $child_stdin "Good boy. You can have ice cream.\n";
    } else {
        print $child_stdin "Bad boy. No ice cream for you.\n";
        sleep 2;
        $child_err = Forks::Super::read_stderr($pid);
        # -or-  $child_err = readline($Forks::Super::CHILD_STDERR{$pid});
        print $child_stdin "And no back talking!\n" if $child_err;
    }

    # ---------- manage jobs and system resources ---------------
    # runs 100 tasks but fork call blocks while there are already 5 active jobs
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'block';
    for ($i=0; $i<100; $i++) {
      $pid = fork { cmd => $task[$i] };
    }

    # jobs fail (without blocking) if the system is too busy
    $Forks::Super::MAX_LOAD = 2.0;
    $Forks::Super::ON_BUSY = 'fail';
    $pid = fork { cmd => $task };
    if    ($pid > 0) { print "'$task' is running\n" }
    elsif ($pid < 0) { print "current CPU load > 2.0 -- didn't start '$task'\n"; }

    # $Forks::Super::MAX_PROC setting can be overridden. 
    # Start job immediately if < 3 jobs running
    $pid = fork { sub => 'MyModule::MyMethod', args => [ @b ], max_proc => 3 };

    # try to fork no matter how busy the system is
    $pid = fork { force => 1, sub => \&MyMethod, args => [ @my_args ] };

    # when system is busy, queue jobs. When system is not busy, 
    #     some jobs on the queue will start.
    # if job is queued, return value from fork() is a very negative number
    $Forks::Super::ON_BUSY = 'queue';
    $pid = fork { cmd => $command };
    $pid = fork { cmd => $useless_command, queue_priority => -5 };
    $pid = fork { cmd => $important_command, queue_priority => 5 };
    $pid = fork { cmd => $future_job, 
                  delay => 20 }       # force job to stay on queue for at least 20s

    # assign descriptive names to tasks
    $pid1 = fork { cmd => $command, name => "my task" };
    $pid2 = waitpid "my task", 0;

    # run callbacks at various points of job life-cycle
    $pid = fork { cmd => $command, callback => \&on_complete };
    $pid = fork { sub => $sub, args => [ @args ],
                  callback => { start => 'on_start', finish => \&on_complete,
                                queue => sub { print "Job $_[1] queued\n" } } };

    # set up dependency relationships
    $pid1 = fork { cmd => $job1 };
    $pid2 = fork { cmd => $job2, 
                   depend_on => $pid1 };            # put on queue until job 1 is complete
    $pid4 = fork { cmd => $job4, 
                   depend_start => [$pid2,$pid3] }; # put on queue until jobs 2,3 have started

    $pid5 = fork { cmd => $job5, name => "group C" };
    $pid6 = fork { cmd => $job6, name => "group C" };
    $pid7 = fork { cmd => $job7, 
                   depend_on => "group C" };        # wait for jobs 5 & 6 to complete

    # manage OS settings on jobs -- may not be available on all systems
    $pid1 = fork { os_priority => 10 };    # like nice(1) on Un*x
    $pid2 = fork { cpu_affinity => 0x5 };  # background task will prefer CPUs #0 and #2

    # job information
    $state = Forks::Super::state($pid);    # 'ACTIVE', 'DEFERRED', 'COMPLETE', 'REAPED'
    $status = Forks::Super::status($pid);  # exit status ($?) for completed jobs

    # --- evaluate long running expressions in the background
    $result = bg_eval { a_long_running_calculation() };
    # sometime later ...
    print "Result was $result\n";

    @result = bg_qx( "./long_running_command" );
    # ... do something else for a while and when you need the output ...
    print "output of long running command was: @result\n";

    # --- convenience methods, compare to IPC::Open2, IPC::Open3
    my ($fh_in, $fh_out, $pid, $job) = Forks::Super::open2(@command);
    my ($fh_in, $fh_out, $fh_err, $pid, $job) 
            = Forks::Super::open3(@command, { timeout => 60 });

=head1 DESCRIPTION

This package provides new definitions for the Perl functions
L<fork|perlfunc/"fork">, L<wait|perlfunc/"wait">, and
L<waitpid|perlfunc/"waitpid"> with richer functionality.
The new features are designed to make it more convenient to
spawn background processes and more convenient to manage them
to get the most out of your system's resources.

=head1 C<$pid = fork( \%options )>

The new C<fork> call attempts to spawn a new process.
With no arguments, it behaves the same as the Perl
L<< fork()|perlfunc/"fork" >> system call.

=over 4

=item *

creating a new process running the same program at the same point

=item *

returning the process id (PID) of the child process to the parent.

On Windows, this is a I<pseudo-process ID>

=item *

returning 0 to the child process

=item *

returning C<undef> if the fork call was unsuccessful

=back

=head2 Options for instructing the child process

The C<fork> call supports three options, L<"cmd">, L<"exec">,
and L<"sub"> (or C<sub>/C<args>)
that will instruct the child process to carry out a specific task.
Using any of these options causes the child process not to
return from the C<fork> call.

=head3 cmd

=over 4

=item C<< $child_pid = fork { cmd => $shell_command } >>

=item C<< $child_pid = fork { cmd => \@shell_command } >>

On successful launch of the child process, runs the specified
shell command in the child process with the Perl 
L<system()|perlfunc/"system_LIST__"> function. When the system call 
is complete, the child process exits with the same exit status
that was returned by the system call.

Returns the PID of the child process to
the parent process. Does not return from the child process, so you
do not need to check the fork() return value to determine whether
code is executing in the parent or child process.

=back

=head3 exec

=over 4

=item C<< $child_pid = fork { exec => $shell_command } >>

=item C<< $child_pid = fork { exec => \@shell_command } >>

Like the L<"cmd"> option, but the background process launches the
shell command with L<exec|perlfunc/"exec"> instead of with 
L<system|perlfunc/"system_LIST__">.

Using C<exec> instead of C<cmd> will spawn one fewer process,
but note that the L<"timeout"> and 
L<"expiration"> options cannot
be used with the C<exec> option (see
L<"Options for simple job management">).

=back

=head3 sub

=over 4

=item C<< $child_pid = fork { sub => $subroutineName [, args => \@args ] } >>

=item C<< $child_pid = fork { sub => \&subroutineReference [, args => \@args ] } >>

=item C<< $child_pid = fork { sub => sub { ... code ... } [, args => \@args ] } >>

On successful launch of the child process, C<fork> invokes the
specified Perl subroutine with the specified set of method arguments
(if provided) in the child process. 
If the subroutine completes normally, the child
process exits with a status of zero. If the subroutine exits
abnormally (i.e., if it C<die>'s, or if the subroutine invokes
C<exit> with a non-zero argument), the child process exits with
non-zero status.

Returns the PID of the child process to the parent process.
Does not return from the child process, so you do not need to
check the fork() return value to determine whether code is running
in the parent or child process.

If neither the L<"cmd">, L<"exec">, 
nor the L<"sub"> option is provided 
to the fork call, then the fork() call behaves like a standard
Perl C<fork()> call, returning the child PID to the parent and also 
returning zero to a new child process.

As of v0.34, the C<fork> function can return an overloaded
L<Forks::Super::Job> object to the parent process instead of
a simple scalar representing the job ID. 
The return value will behave like the simple scalar
in any numerical context but the attributes and methods of
L<Forks::Super::Job> will also be available. See 
L<Forks::Super::Job/"OVERLOADING"> for more details including
how to disable/enable this feature.

=back

=head2 Options for simple job management

=head3 timeout

=head3 expiration

=over 4

=item C<< fork { timeout => $delay_in_seconds } >>

=item C<< fork { expiration => $timestamp_in_seconds_since_epoch_time } >>

Puts a deadline on the child process and causes the child to C<die>
if it has not completed by the deadline. With the C<timeout> option,
you specify that the child process should not survive longer than the
specified number of seconds. With C<expiration>, you are specifying
an epoch time (like the one returned by the L<time|perlfunc/"time__">
function) as the child process's deadline.

If the L<setpgrp()|perlfunc/"setpgrp"> system call is implemented 
on your system, then this module will try to reset the process group
 ID of the child process. On timeout, the module will attempt to kill 
off all subprocesses of the expiring child process.

If the deadline is some time in the past (if the timeout is
not positive, or the expiration is earlier than the current time),
then the child process will die immediately after it is created.

Note that this feature uses the Perl L<alarm|perlfunc/"alarm">
call and installs its own handler for C<SIGALRM>. Do not use this
feature with a child L<sub|"sub"> that also uses C<alarm> or that
installs another C<SIGALRM> handler, or the results will be
undefined.

The C<timeout> and C<expiration> options cannot be used with the
L<"exec"> option, since the child process will not be able to
generate a C<SIGALRM> after an C<exec> call.

If you have installed the L<DateTime::Format::Natural> module,
then you may also specify the timeout and expiration options using
natural language:

    $pid = fork { timeout => "in 5 minutes", sub => ... };

    $pid = fork { expiration => "next Wednesday", cmd => $long_running_cmd };

=back

=head3 dir

=over 4

=item C<< fork { dir => $directory } >>

=item C<< fork { chdir => $directory } >>

Causes the child process to be run from a different directory 
than the parent.

If the specified directory does not exist or if the C<chdir>
call fails (e.g, if the caller does not have permission to 
change to the directory), then the child process immediately
exits and will have a non-zero exit status.

C<chdir> and C<dir> are synonyms.

=back

=head3 delay

=head3 start_after

=over 4

=item C<< fork { delay => $delay_in_seconds } >>

=item C<< fork { start_after => $timestamp_in_epoch_time } >>

Causes the child process to be spawned at some time in the future.
The return value from a C<fork> call that uses these features
will not be a process id, but it will be a very negative number
called a job ID. See the section on L<"Deferred processes">
for information on what to do with a job ID.

A deferred job will start B<no earlier> than its appointed time
in the future. Depending on what circumstances the queued jobs
are examined, B<the actual start time of the job could be significantly
later than the appointed time>.

A job may have both a minimum start time (through C<delay> or
C<start_after> options) and a maximum end time (through
L<"timeout"> and L<"expiration">). 
Jobs with inconsistent times
(end time is not later than start time) will be killed of
as soon as they are created.

As with the L<"timeout"> and L<"expiration"> options, the
C<delay> and C<start_after> options can be expressed in
natural language if you have installed the
L<DateTime::Format::Natural> module.

    $pid = fork { start_after => "12:25pm tomorrow",  sub => ... };

    $pid = fork { delay => "in 7 minutes", cmd => ... };

=back

=head3 child_fh

=over 4

=item C<< fork { child_fh => $fh_spec } >>

=item C<< fork { child_fh => [ @fh_spec ] } >>

Launches a child process and makes the child process's
C<STDIN>, C<STDOUT>, and/or C<STDERR> filehandles available to
the parent process in the scalar variables
C<$Forks::Super::CHILD_STDIN{$pid}>,
C<$Forks::Super::CHILD_STDOUT{$pid}>, and/or
C<$Forks::Super::CHILD_STDERR{$pid}>, where C<$pid> is the PID
return value from the fork call. This feature makes it possible,
even convenient, for a parent process to communicate with a
child, as this contrived example shows.

    $pid = fork { sub => \&pig_latinize, timeout => 10,
                  child_fh => "all" };

    # in the parent, $Forks::Super::CHILD_STDIN{$pid} is an *output* filehandle
    print {$Forks::Super::CHILD_STDIN{$pid}} "The blue jay flew away in May\n";

    sleep 2; # give child time to start up and get ready for input

    # and $Forks::Super::CHILD_STDOUT{$pid} is an *input* handle
    $result = <{$Forks::Super::CHILD_STDOUT{$pid}}>;
    print "Pig Latin translator says: $result\n"; # ==> eThay ueblay ayjay ewflay awayay inay ayMay\n
    @errors = <{$Forks::Super::CHILD_STDERR{$pid}>;
    print "Pig Latin translator complains: @errors\n" if @errors > 0;

    sub pig_latinize {
      for (;;) {
        while (<STDIN>) {
	  foreach my $word (split /\s+/) {
            if ($word =~ /^qu/i) {
              print substr($word,2) . substr($word,0,2) . "ay";  # STDOUT
            } elsif ($word =~ /^([b-df-hj-np-tv-z][b-df-hj-np-tv-xz]*)/i) {
              my $prefix = 1;
              $word =~ s/[b-df-hj-np-tv-z][b-df-hj-np-tv-xz]*//i;
	      print $word . $prefix . "ay";
	    } elsif ($word =~ /^[aeiou]/i) {
              print $word . "ay";
            } else {
	      print STDERR "Didn't recognize this word: $word\n";
            }
            print " ";
          }
	  print "\n";
        }
      }
    }

The set of filehandles to make available are specified either as
a non-alphanumeric delimited string, or list reference. This spec
may contain one or more of the words C<in>, C<out>, C<err>,
C<join>, C<all>, C<socket>, C<pipe>, and C<block>.

C<in>, C<out>, and C<err> mean that the child's STDIN, STDOUT,
and STDERR, respectively, will be available in the parent process
through the filehandles in C<$Forks::Super::CHILD_STDIN{$pid}>,
C<$Forks::Super::CHILD_STDOUT{$pid}>,
and C<$Forks::Super::CHILD_STDERR{$pid}>, where C<$pid> is the
child's process ID. C<all> is a convenient way to specify
C<in>, C<out>, and C<err>. C<join> specifies that the child's
STDOUT and STDERR will be returned through the same filehandle,
specified as both C<$Forks::Super::CHILD_STDOUT{$pid}> and
C<$Forks::Super::CHILD_STDERR{$pid}>.

If C<socket> is specified, then local sockets will be used to
pass between parent and child instead of temporary files.

If C<pipe> is specified, then local pipes will be used to
pass between parent and child instead of temporary files.

If C<block> is specified, then the read end of each 
filehandle will block until input is available.
Note that this can lead to deadlock unless the I/O of the
write end of the filehandle is carefully managed.

=cut

This syntax will be extended and cleaned up in 1.0.

=back

=head3 Socket handles vs. file handles vs. pipes

Here are some things to keep in mind when deciding whether to
use sockets, pipes, or regular files for parent-child IPC:

=over 4

=item *

Using regular files is implemented everywhere and is the
most portable and robust scheme for IPC. Sockets and pipes
are best suited for Unix-like systems, and may have
limitations on non-Unix systems.

=item *

Sockets and pipes have a performance advantage, especially at
child process start-up.

=item *

Temporary files use disk space; sockets and pipes use memory. 
One of these might be a relatively scarce resource on your
system.

=item *

Socket input buffers have limited capacity. Write operations
can block if the socket reader is not vigilant. Pipe input
buffers are often even smaller (as small as 512 bytes on
some modern systems).

I<The> C<Forks/Super/SysInfo.pm> I<file that is created
at build time will have information about the socket and
pipe capacity of your system, if you are interested.>

=item *

On Windows, sockets and pipes are blocking, and care must be taken
to prevent your script from reading on an empty socket. In
addition, sockets to the input/output streams of external
programs on Windows is a little flaky, so you are almost always
better off using filehandles for IPC if your Windows program
needs external commands (the C<cmd> or C<exec> options to
C<Forks::Super::fork>).

=back

=cut

=head3 Socket and file handle gotchas

Some things to keep in mind when using socket or file handles
to communicate with a child process.

=over 4

=item *

care should be taken before calling L<close|perlfunc/"close">
on a socket handle.
The same socket handle can be used for both reading and writing.
Don't close a handle when you are only done with one half of the
socket operations.

In general, the C<Forks::Super> module knows whether a filehandle
is associated with a file, a socket, or a pipe, 
and the L<"close_fh">
function provides a safe way to close the file handles associated
with a background task:

    Forks::Super::close_fh($pid);          # close all STDxxx handles
    Forks::Super::close_fh($pid, 'stdin'); # close STDIN only
    Forks::Super::close_fh($pid, 'stdout', 'stderr'); # don't close STDIN

=item *

The test C<Forks::Super::Util::is_socket($handle)> can determine
whether C<$handle> is a socket handle or a regular filehandle.
The test C<Forks::Super::Util::is_pipe($handle)> 
can determine whether C<$handle> is reading from or writing to a pipe.

=cut

XXX This is the only documentation for the 
Forks::Super::Util::is_socket/is_pipe functions.

=item *

IPC in this module is asynchronous. In general, you
cannot tell whether the parent/child has written anything to
be read in the child/parent. So getting C<undef> when reading
from the C<$Forks::Super::CHILD_STDOUT{$pid}> handle does not
necessarily mean that the child has finished (or even started!)
writing to its STDOUT. Check out the C<seek HANDLE,0,1> trick
in L<the perlfunc documentation for seek|perlfunc/seek>
about reading from a handle after you have
already read past the end. You may find it useful for your
parent and child processes to follow some convention (for example,
a special word like C<"__END__">) to denote the end of input.

=back

=head3 stdin

=over 4

=item C<< fork { stdin => $input } >>

Provides the data in C<$input> as the child process's standard input.
Equivalent to, but a little more efficient than:

    $pid = fork { child_fh => "in", sub => sub { ... } };
    print {$Forks::Super::CHILD_STDIN{$pid}} $input;

C<$input> may either be a scalar, a reference to a scalar, or
a reference to an array.

=back

=head3 stdout

=head3 stderr

=over 4

=item C<< fork { stdout => \$output } >>

=item C<< fork { stderr => \$errput } >>

On completion of the background process, loads the standard output
and standard error of the child process into the given scalar
references. If you do not need to use the child's output while
the child is running, it could be more convenient to use this
construction than calling L<Forks::Super::read_stdout($pid)|/"read_stdout">
(or C<< <{$Forks::Super::CHILD_STDOUT{$pid}}> >>) to obtain
the child's output.

=item C<< fork { retries => $max_retries } >>

If the underlying system C<fork> call fails (returns
C<undef>), pause for a short time and retry up to
C<$max_retries> times.

This feature is probably not that useful. A failed
C<fork> call usually indicates some bad system condition
(too many processes, system out of memory or swap space,
impending kernel panic, etc.) where your expectations
of recovery should not be too high.

=back

=head2 Options for complicated job management

The C<fork()> call from this module supports options that help to
manage child processes or groups of child processes in ways to better
manage your system's resources. For example, you may have a lot of
tasks to perform in the background, but you don't want to overwhelm
your (possibly shared) system by running them all at once. There
are features to control how many, how, and when your jobs will run.

=head3 name

=over 4

=item C<< fork { name => $name } >>

Attaches a string identifier to the job. The identifier can be used
for several purposes:

=over 4

=item * to obtain a L<Forks::Super::Job> object representing the
background task through the 
L<Forks::Super::Job::get|Forks::Super::Job/"get"> or
L<Forks::Super::Job::getByName|Forks::Super::Job/"getByName"> methods.

=item * as the first argument to L<"waitpid"> to wait on a job or jobs
with specific names

=item * to identify and establish dependencies between background
tasks. See the L<"depend_on"> 
and L<"depend_start"> parameters below.

=item * if supported by your system, the name attribute will change
the argument area used by the ps(1) program and change the
way the background process is displaying in your process viewer.
(See L<$PROGRAM_NAME in perlvar|perlvar/"$PROGRAM_NAME">
about overriding the special C<$0> variable.)

=back

=back

=head3 max_fork

=over 4

=item C<$Forks::Super::MAX_PROC = $max_simultaneous_jobs>

=item C<< fork { max_fork => $max_simultaneous_jobs } >>

Specifies the maximum number of background processes that you want
to run. If a C<fork> call is attempted while there are already
the maximum number of child processes running, then the C<fork()>
call will either block (until some child processes complete),
fail (return a negative value without spawning the child process),
or queue the job (returning a very negative value called a job ID),
according to the specified "on_busy" behavior (see the next item).
See the L<"Deferred processes"> 
section for information about
how queued jobs are handled.

On any individual C<fork> call, the maximum number of processes may be
overridden by also specifying C<max_proc> or L<"force"> options.

    $Forks::Super::MAX_PROC = 8;
    # launch 2nd job only when system is very not busy
    $pid1 = fork { sub => 'method1' };
    $pid2 = fork { sub => 'method2', max_proc => 1 };
    $pid3 = fork { sub => 'method3' };

Setting C<$Forks::Super::MAX_PROC> to zero or a negative number will
disable the check for too many simultaneous processes.

=item C<$Forks::Super::MAX_LOAD = $max_cpu_load>

=item C<< fork { max_load => $max_cpu_load } >>

Specifies a maximum CPU load threshold. The C<fork>
command will not spawn any new jobs while the current
system CPU load is larger than this threshold.
CPU load checks are disabled if this value is set to zero
or to a negative number.

B<Note that the metric of "CPU load" is different on 
different operating systems>. 
On Windows (including Cygwin), the metric is CPU
utilization, which is always a value between 0 and 1.
On Unix-ish systems, the metric is the 1-minute system 
load average, which could be a value larger than 1. 
Also note that the 1-minute average load measurement
has a lot of inertia -- after you start or stop a CPU 
intensive task, it will take at least several seconds
for that change to have a large impact on the 1-minute
utilization.

If your system does not have a well-behaved L<uptime(1)>
command, then you may need to install the L<Sys::CpuLoadX>
module to use this feature. For now, the C<Sys::CpuLoadX>
module is only available bundled with C<Forks::Super> and
otherwise cannot be downloaded from CPAN.

=back

=head3 on_busy

=over 4

=item C<$Forks::Super::ON_BUSY = "block" | "fail" | "queue">

=item C<< fork { on_busy => "block" | "fail" | "queue" } >>

Dictates the behavior of C<fork> in the event that the module is not allowed
to launch the specified job for whatever reason. If you are using
C<Forks::Super> to throttle (see L<max_fork, $Forks::Super::MAX_PROC|"max_fork">)
or impose dependencies on (see L<depend_start|"depend_start">, L<depend_on|"depend_on">)
background processes, then failure to launch a job should be expected.

=over 4

=item C<block>

If the module cannot create a new child process for the specified job,
it will wait and periodically retry to create the child process until
it is successful. Unless a system fork call is attempted and fails,
C<fork> calls that use this behavior will return a positive PID.

=item C<fail>

If the module cannot immediately create a new child process 
for the specified job, the C<fork> call will return with a 
small negative value.

=item C<queue>

If the module cannot create a new child process for the specified job,
the job will be deferred, and an attempt will be made to launch the
job at a later time. See L<"Deferred processes"> 
below. The return
value will be a very negative number (job ID).

=back

On any individual C<fork> call, the default launch failure behavior specified
by L<$Forks::Super::ON_BUSY|/"ON_BUSY"> can be overridden by specifying a
C<on_busy> option:

    $Forks::Super::ON_BUSY = "fail";
    $pid1 = fork { sub => 'myMethod' };
    $pid2 = fork { sub => 'yourMethod', on_busy => "queue" }

=back

=head3 force

=over 4

=item C<< fork { force => $bool } >>

If the C<force> option is set, the C<fork> call will disregard the
usual criteria for deciding whether a job can spawn a child process,
and will always attempt to create the child process.

=back

=head3 queue_priority

=over 4

=item C<< fork { queue_priority => $priority } >>

In the event that a job cannot immediately create a child process and
is put on the job queue (see L<"Deferred processes">), the C{queue_priority}
specifies the relative priority of the job on the job queue. In general,
eligible jobs with high priority values will be started before jobs
with lower priority values.

=back

=head3 depend_on

=head3 depend_start

=over 4

=item C<< fork { depend_on => $id } >>

=item C<< fork { depend_on => [ $id_1, $id_2, ... ] } >>

=item C<< fork { depend_start => $id } >>

=item C<< fork { depend_start => [ $id_1, $id_2, ... ] } >>

Indicates a dependency relationship between the job in this C<fork>
call and one or more other jobs. The identifiers may be
process/job IDs or L<"name"> attributes (see above) from
earlier C<fork> calls.

If a C<fork> call specifies a
C<depend_on> option, then that job will be deferred until
all of the child processes specified by the process or job IDs
have B<completed>. If a C<fork> call specifies a
C<depend_start> option, then that job will be deferred until
all of the child processes specified by the process or job
IDs have B<started>.

Invalid process and job IDs in a C<depend_on> or C<depend_start>
setting will produce a warning message but will not prevent
a job from starting.

Dependencies are established at the time of the C<fork> call
and can only apply to jobs that are known at run time. So for
example, in this code,

    $job1 = fork { cmd => $cmd, name => "job1", depend_on => "job2" };
    $job2 = fork { cmd => $cmd, name => "job2", depend_on => "job1" };

at the time the first job is cereated, the job named "job2" has not
been created yet, so the first job will not have a dependency (and a
warning will be issued when the job is created). This may
be a limitation but it also guarantees that there will be no
circular dependencies.

When a dependency identifier is a name attribute that applies to multiple
jobs, the job will be dependent on B<all> existing jobs with that name:

    # Job 3 will not start until BOTH job 1 and job 2 are done
    $job1 = fork { name => "Sally", ... };
    $job2 = fork { name => "Sally", ... };
    $job3 = fork { depend_on => "Sally", ... };

    # all of these jobs have the same name and depend on ALL previous jobs
    $job4 = fork { name => "Ralph", depend_start => "Ralph", ... }; # no dependencies
    $job5 = fork { name => "Ralph", depend_start => "Ralph", ... }; # depends on Job 4
    $job6 = fork { name => "Ralph", depend_start => "Ralph", ... }; # depends on #4 and #5

=back

=head3 can_launch

=over 4

=item C<< fork { can_launch => \&methodName } >>

=item C<< fork { can_launch => sub { ... anonymous sub ... } } >>

Supply a user-specified function to determine when a job is
eligible to be started. The function supplied should return
0 if a job is not eligible to start and non-zero if it is
eligible to start.

During a C<fork> call or when the job queue is being examined,
the user's C<can_launch> method will be invoked with a single
C<Forks::Super::Job> argument containing information about the job
to be launched. User code may make use of the default launch
determination method by invoking the C<_can_launch> method
of the job object:

    # Running on a BSD system with the uptime(1) call.
    # Want to block jobs when the current CPU load
    # (1 minute) is greater than 4 and respect all other criteria:
    fork { cmd => $my_command,
           can_launch => sub {
             $job = shift;                    # a Forks::Super::Job object
             return 0 if !$job->_can_launch;  # default
             $cpu_load = (split /\s+/,`uptime`)[-3]; # get 1 minute avg CPU load
             return 0 if $cpu_load > 4.0;     # system too busy. let's wait
             return 1;
           } }

=back

=head3 callback

=over 4

=item C<< fork { callback => $subroutineName } >>

=item C<< fork { callback => sub { BLOCK } } >>

=item C<< fork { callback => { start => ..., finish => ..., queue => ..., fail => ... } } >>

Install callbacks to be run when and if certain events in the life cycle
of a background process occur. The first two forms of this option
are equivalent to

    fork { callback => { finish => ... } }

and specify code that will be executed when a background process is complete
and the module has received its C<SIGCHLD> event. A C<start> callback is
executed just after a new process is spawned. A C<queue> callback is run
if and only if the job is deferred for any reason 
(see L<"Deferred processes">) and
the job is placed onto the job queue for the first time. And the C<fail>
callback is run if the job is not going to be launched (that is, a case
where the C<fork> call would return C<-1>).

Callbacks are invoked with two arguments:
the L<Forks::Super::Job> object that was created with the original
C<fork> call, and the job's ID (the return value from C<fork>).

You should keep your callback functions short and sweet, like you do
for your signal handlers. Sometimes callbacks are invoked from the
signal handler, and the processing of other signals could be
delayed if the callback functions take too long to run.

=back

=head3 suspend

=over 4

=item C<< fork { suspend => 'subroutineName' } } >>

=item C<< fork { suspend => \&subroutineName } } >>

=item C<< fork { suspend => sub { ... anonymous sub ... } } >>

Registers a callback function that can indicate when a background
process should be suspended and when it should be resumed.
The callback function will receive one argument -- the
L<Forks::Super::Job> object that owns the callback -- and is
expected to return a numerical value. The callback function
will be evaluated periodically (for example, during the
productive downtime of a L<"wait">/L<"waitpid"> call or
C<Forks::Super::Util::pause()> call).

When the callback function returns a negative value 
and the process is active, the process will be suspended.

When the callback function returns a positive value
while the process is suspended, the process will be resumed.

When the callback function returns 0, the job will
remain in its current state.

    my $pid = fork { exec => "run-the-heater",
                     suspend => sub {
                       my $t = get_temperature();
                       if ($t < 68) {
                           return +1;  # too cold, make sure heater is on
                       } elsif ($t > 72) {
                           return -1;  # too warm, suspend the heater process
                       } else {
                           return 0;   # leave it on or off
                       }
                    } };


=back

=head3 os_priority

=over 4

=item C<< fork { os_priority => $priority } >>

On supported operating systems, and after the successful creation
of the child process, attempt to set the operating system priority
of the child process, using your operating system's notion of
what priority is.

On unsupported systems, this option is ignored.

=back

=head3 cpu_affinity

=over 4

=item C<< fork { cpu_affinity => $bitmask } >>

=item C<< fork { cpu_affinity => [ @list_of_processors ] } >>

On supported operating systems with multiple cores,
and after the successful creation of the child process,
attempt to set the child process's CPU affinity.

In the scalar style of this option, each bit of the bitmask represents
one processor. Set a bit to 1 to allow the process to use the 
corresponding processor, and set it to 0 to disallow the corresponding
processor.

For example, to bind a new child process to use CPU #s 2 and 3
on a system with (at least) 4 processors, you would call one of

    fork { cpu_affinity => 12 , ... } ;    # 12 = 1<<2 + 1<<3
    fork { cpu_affinity => [2,3] , ... };

There may be additional restrictions on the range of valid
values for the C<cpu_affinity> option imposed by the operating
system. See L<the Sys::CpuAffinity docs|Sys::CpuAffinity> for
discussion of some of these restrictions.

This feature requires the L<Sys::CpuAffinity|Sys::CpuAffinity>
module. The C<Sys::CpuAffinity> module is bundled with C<Forks::Super>,
or it may be obtained from CPAN.

=back

=head3 debug

=head3 undebug

=over 4

=item C<< fork { debug => $bool } >>

=item C<< fork { undebug => $bool } >>

Overrides the value in C<$Forks::Super::DEBUG> (see L<"MODULE VARIABLES">)
for this specific job. If specified, the C<debug> parameter
controls only whether the module will output debugging information related
to the job created by this C<fork> call.

Normally, the debugging settings of the parent, including the job-specific
settings, are inherited by child processes. If the C<undebug> option is
specified with a non-zero parameter value, then debugging will be
disabled in the child process.

=back

=head2 Deferred processes

Whenever some condition exists that prevents a C<fork()> call from
immediately starting a new child process, an option is to B<defer>
the job. Deferred jobs are placed on a queue. At periodic intervals,
in response to periodic events, or whenever you invoke the
C<Forks::Super::Queue::check_queue> method in your code, 
the queue will be examined to see if any deferred jobs are 
eligible to be launched.

=head3 Job ID

When a C<fork()> call fails to spawn a child process but instead
defers the job by adding it to the queue, the C<fork()> call will
return a unique, large negative number called the job ID. The
number will be negative and large enough (E<lt>= -100000) so
that it can be distinguished from any possible PID,
Windows pseudo-process ID, process group ID, or C<fork()>
failure code.

Although the job ID is not the actual ID of a system process,
it may be used like a PID as an argument to L<"waitpid">,
as a dependency specification in another C<fork> call's
L<"depend_on"> or L<"depend_start"> option, or
the other module methods used to retrieve job information
(See L</"Obtaining job information"> below). Once a deferred
job has been started, it will be possible to obtain the
actual PID (or on Windows, the actual
psuedo-process ID) of the process running that job.

=head3 Job priority

Every job on the queue will have a priority value. A job's
priority may be set explicitly by including the
L<"queue_priority"> option in the C<fork()> call, or it will
be assigned a default priority near zero. Every time the
queue is examined, the queue will be sorted by this priority
value and an attempt will be made to launch each job in this
order. Note that different jobs may have different criteria
for being launched, and it is possible that that an eligible
low priority job may be started before an ineligible
higher priority job.

=head3 Queue examination

Certain events in the C<SIGCHLD> handler or in the
L<"wait">, L<"waitpid">, 
and/or L<"waitall"> methods will cause
the list of deferred jobs to be evaluated and to start
eligible jobs. But this configuration does not guarantee
that the queue will be examined in a timely or frequent
enough basis. The user may invoke the

    Forks::Super::Queue:check_queue()

method at any time to force the queue to be examined.

=head2 Special tips for Windows systems

On POSIX systems (including Cygwin), programs using the
C<Forks::Super> module are interrupted when a child process
completes. A callback function performs some housekeeping
and may perform other duties like trying to dispatch
things from the list of deferred jobs.

Windows systems do not have the signal handling capabilities
of other systems, and so other things equal, a script
running on Windows will not perform the housekeeping
tasks as frequently as a script on other systems.

The method C<Forks::Super::pause> can be used as a drop in
replacement for the Perl C<sleep> call. In a C<pause>
function call, the program will check on active
child processes, reap the ones that have completed, and
attempt to dispatch jobs on the queue.

Calling C<pause> with an argument of 0 is also a valid
way of invoking the child handler function on Windows.
When used this way, C<pause> returns immediately after
running the child handler.

Child processes are implemented differently in Windows
than in POSIX systems. The C<CORE::fork> and C<Forks::Super::fork>
calls will usually return a B<pseudo-process ID> to the
parent process, and this will be a B<negative value>.
The Unix idiom of testing whether a C<fork> call returns
a positive number needs to be modified on Windows systems
by testing whether  C<Forks::Super::isValidPid($pid)> returns
true, where C<$pid> is the return value from a C<Forks::Super::fork>
call.

=head1 OTHER FUNCTIONS

=head2 Process monitoring and signalling

=head3 wait

=over 4

=item C<$reaped_pid = wait [$timeout] >

Like the Perl L<< wait|perlfunc/wait >> system call,
blocks until a child process
terminates and returns the PID of the deceased process,
or C<-1> if there are no child processes remaining to reap.
The exit status of the child is returned in 
L<$?|perlvar/"$CHILD_ERROR">.

This version of the C<wait> call can take an optional
C<$timeout> argument, which specifies the maximum length of
time in seconds to wait for a process to complete.
If a timeout is supplied and no process completes before the
timeout expires, then the C<wait> function returns the
value C<-1.5> (you can also test if the return value of the
function is the same as L<Forks::Super::TIMEOUT|/"TIMEOUT">, which
is a constant to indicate that a wait call timed out).

If C<wait> (or L<"waitpid"> or L<"waitall">) is called when
all jobs are either complete or suspended, and there is
at least one suspended job, then the behavior is
governed by the setting of the L<<
$Forks::Super::WAIT_ACTION_ON_SUSPENDED_JOBS|/"WAIT_ACTION_ON_SUSPENDED_JOBS"
>> variable.

=back

=head3 waitpid

=over 4

=item C<$reaped_pid = waitpid $pid, $flags [, $timeout] >

Waits for a child with a particular PID or a child from
a particular process group to terminate and returns the
PID of the deceased process, or C<-1> if there is no
suitable child process to reap. If the return value contains
a PID, then L<$?|perlvar/"$CHILD_ERROR"> 
is set to the exit status of that process.

A valid job ID (see L<"Deferred processes">) may be used
as the $pid argument to this method. If the C<waitpid> call
reaps the process associated with the job ID, the return value
will be the actual PID of the deceased child.

Note that the C<waitpid> function can wait on a
job ID even when the job associated with that ID is
still in the job queue, waiting to be started.

A $pid value of C<-1> waits for the first available child
process to terminate and returns its PID.

A $pid value of C<0> waits for the first available child
from the same process group of the calling process.

A negative C<$pid> that is not recognized as a valid job ID
will be interpreted as a process group ID, and the C<waitpid>
function will return the PID of the first available child
from the same process group.

On some^H^H^H^H every modern system that I know about,
 a C<$flags> value of C<POSIX::WNOHANG>
is supported to perform a non-blocking wait. See the
Perl L<< waitpid|perlfunc/waitpid >> documentation.

If the optional C<$timeout> argument is provided, the C<waitpid>
function will block for at most C<$timeout> seconds, and
return C<-1.5> (or L<Forks::Super::TIMEOUT|/"TIMEOUT"> if a suitable
process is not reaped in that time.

=cut

=back

=head3 waitall

=over 4

=item C<$count = waitall [$timeout] >

Blocking wait for all child processes, including deferred
jobs that have not started at the time of the C<waitall>
call. Return value is the number of processes that were
waited on.

If the optional C<$timeout> argument is supplied, the
function will block for at most C<$timeout> seconds before
returning.

=back

=head3 kill

=over 4

=item C<$num_signalled = Forks::Super::kill $signal, @jobsOrPids>

Send a signal to the background processes specified
either by process IDs, job names, or L<Forks::Super::Job>
objects. Returns the number of jobs that were successfully
signalled.

This method "does what you mean" with respect to terminating,
suspending, or resuming processes. In this way, you may "send
signals" to jobs in the job queue (that don't even have a proper 
process id yet). On Windows systems, which do not have a Unix-like
signals framework, this can be accomplished through 
the appropriate Windows API calls. It is highly recommended
that you install the L<Win32::API> module for this purpose.

See also the L<< 
Forks::Super::Job::suspend|Forks::Super::Job/"$job->suspend" >>
and L<< resume|Forks::Super::Job/"$job->resume" >> methods. It is
preferable (out of portability concerns) to use these methods

    $job->suspend;
    $job->resume;

rather than C<Forks::Super::kill>.

    Forks::Super::kill 'STOP', $job;
    Forks::Super::kill 'CONT', $job;

=back

=head3 kill_all

=over 4

=item C<$num_signalled = Forks::Super::kill_all $signal>

Sends a "signal" (see expanded meaning of "signal" in
L<"kill">, above). to all relevant processes spawned from the
C<Forks::Super> module. 

=back

=head3 isValidPid

=over 4

=item C<Forks::Super::isValidPid( $pid )>

Tests whether the return value of a C<fork> call indicates that
a background process has been successfully created or not. On POSIX-y
systems it is sufficient to check whether C<$pid> is a
positive integer, but C<isValidPid> is a more portable way
to test the return value as it also identifies I<psuedo-process IDs>
on Windows systems, which are typically negative numbers.

C<isValidPid> will return false for a large negative process id,
which the C<fork> call returns to indicate that a job has been
deferred (see L<"Deferred processes">). Of course it is possible
that the job will run later and have a valid process id associated
with it.

=cut

XXX Undocumented second argument to override DWIM behavior
    of treating completed jobs like their real PID and
    other jobs like their initial PID

=back

=head2 Interprocess communication functions

=head3 read_stdout

=head3 read_stderr

=over 4

=item C<$line = Forks::Super::read_stdout($pid [,%options] )>

=item C<@lines = Forks::Super::read_stdout($pid [,%options] )>

=item C<$line = Forks::Super::read_stderr($pid [, %options])>

=item C<@lines = Forks::Super::read_stderr($pid [, %options] )>

=item C<< $line = $job->read_stdout( [%options] ) >>

=item C<< @lines = $job->read_stdout( [%options] ) >>

=item C<< $line = $job->read_stderr( [%options]) >>

=item C<< @lines = $job->read_stderr( [%options] ) >>

For jobs that were started with the C<< child_fh => "out" >>
and C<< child_fh => "err" >> options enabled, read data from
the STDOUT and STDERR filehandles of child processes.

Aside from the more readable syntax, these functions may be preferable to
some alternate ways of reading from an interprocess I/O handle

    $line = < {$Forks::Super::CHILD_STDOUT{$pid}} >;
    @lines = < {$job->{child_stdout}} >;
    @lines = < {$Forks::Super::CHILD_STDERR{$pid}} >;
    $line = < {$job->{child_stderr}} >;

because the C<read_stdout> and C<read_stderr> functions will

=over 4

=item * clear the EOF condition when the parent is reading from
the handle faster than the child is writing to it

=item * not block. 

=back

Functions work in both scalar and list context. If there is no data to
read on the filehandle, but the child process is still active and could
put more data on the filehandle, these functions return  C<""> (empty
string) in scalar context and C<()> (empty list) in list context.
If there is no more data on the filehandle and the
child process is finished, the return values of the functions
will be C<undef>.

These methods all take any number of arbitrary key-value
pairs as additional arguments. There are currently three
recognized options to these methods:

=over 4

=item * block => 0 | 1

Determines whether blocking I/O is used on the file, socket,
or pipe handle. If enabled, the 
L<read_stdXXX|Forks::Super::Job/"read_stdout"> function will
hang until input is available or until the module can determine
that the process creating input for that handle has completed.
Blocking I/O can lead to deadlocks unless you are careful about
managing the process creating input for the handle. The default
mode is non-blocking.

=item * warn => 0 | 1

If warnings on the L<read_stdXXX|Forks::Super::Job/"read_stdout"> function
are disabled, then some warning messages (reading from a closed
handle, reading from a non-existent/unconfigured handle) will
be suppressed. Enabled by default.

Note that the output of the child process may be buffered, and
data on the channel that C<read_stdout> and C<read_stderr> read
from may not be available until the child process has produced
a lot of output, or until the child process has finished.
C<Forks::Super> will make an effort to autoflush the filehandles
that write from one process and are read in another process,
but assuring that arbitrary external commands will flush
their output regularly is beyond the scope of this module.

=item * timeout => $num_seconds

On an otherwise non-blocking filehandle, waits up to the
specified number of seconds for input to become available.

The C<< <> >> operator has been overloaded for the 
L<Forks::Super::Job|Forks::Super::Job> package such that 
calling

    <$job>

is equivalent to calling

    scalar $job->read_stdout()

=back

=back

=head3 close_fh

=over 4

=item C<Forks::Super::close_fh($pid)>

Closes all open file handles and socket handles for interprocess communication
with the specified child process. Most operating systems impose a hard limit
on the number of filehandles that can be opened in a process simultaneously,
so you should use this function when you are finished communicating with
a child process so that you don't run into that limit.

=back

=head3 open2

=head3 open3

=over 4

=item C< ($in,$out,$pid,$job) = Forks::Super::open2( @command [, \%options ] )>

=item C< ($in,$out,$err,$pid,$job) = Forks::Super::open3( @command [, \%options] )>

Starts a background process and returns filehandles to the process's
standard input and standard output (and standard error in the case
of the C<open3> call). Also returns the process id and the
L<Forks::Super::Job> object associated with the background process.

Compare these methods to the main functions of the L<IPC::Open2> 
and L<IPC::Open3> modules.

Many of the options that can be passed to C<Forks::Super::fork> can also
be passed to C<Forks::Super::open2> and C<Forks::Super::open3>:

    # run a command but kill it after 30 seconds
    ($in,$out,$pid) = Forks::Super::open2("ssh me\@mycomputer ./runCommand.sh", { timeout => 30 });

    # invoke a callback when command ends
    ($in,$out,$err,$pid,$job) = Forks::Super::open3(@cmd, {callback => sub { print "\@cmd finished!\n" }});

=back

=head3 bg_eval

=over 4

=item C<< $result = bg_eval { BLOCK } >>

=item C<< $result = bg_eval { BLOCK } { option => value, ... } >>

=item C<< @result = bg_eval { BLOCK } >>

=item C<< @result = bg_eval { BLOCK } { option => value, ... } >>

B<< API change since v0.43: In scalar context, the result is now
an overloaded object that retrieves its value when it is I<used> in
an expression. It is no longer a scalar I<reference> that retrieves
its value when it is I<dereferenced>. >>

Launches a block of code in a background process, returning immediately.
The block of code can be evaluated in either scalar or list context.
The next time the result of the function call is referenced, interprocess
communication is used to retrieve the result of the child process, waiting
until the child finishes, if necessary.

    $result = bg_eval { sleep 3; return 42 };  # this line returns immediately
    print "Result was $result\n";              # this line takes 3 seconds to execute

With the C<bg_eval> function, you can perform other tasks while waiting for
the results of another task to be available.

    @result = bg_eval { sleep 5; return (1,2,3) };
    do_something_that_takes_about_5_seconds();
    print "Result was @result\n";              # now this line probably runs immediately

The background process is spawned with the C<Forks::Super::fork> call,
and will block, fail, or defer a job in accordance with all the other rules
of this module. Additional options may be passed to C<bg_eval> that will
be provided to the C<fork> call. Most valid options to the C<fork> call
are also valid for the C<bg_eval> call, including timeouts, delays, job
dependencies, names, and callbacks. This example will populate C<$result>
with the value C<undef> if the C<bg_eval> operation takes longer 
than 60 seconds. 

    # run task in background, but timeout after 20 seconds
    $result = bg_eval {
        download_from_teh_Internet($url, @options)
    } { timeout => 20, os_priority => 3 };
    do_something_eles();
    if (!defined($result)) {
        # operation probably timed out ...
    } else {
        # operation probably succeeded, use $result
    }

An additional option that is recognized by C<bg_eval> (and L<"bg_qx">,
see below) is C<untaint>. If you are running perl in "taint" mode, the
value(s) returned by C<bg_eval> and C<bg_qx> are likely to be "tainted".
By passing the C<untaint> option (assigned to a true value), the values
returned by C<bg_eval> and C<bg_qx> will be taint clean.


Calls to C<bg_eval> (and L<"bg_qx">) will populate the 
variables C<$Forks::Super::LAST_JOB> and C<$Forks::Super::LAST_JOB_ID>
with the L<Forks::Super::Job> object and the job id, respectively,
for the job created by the C<bg_eval>/C<bg_qx> call. 
See L<MODULE VARIABLES/"LAST_JOB"> below.

See also: L<"bg_qx">.

=back

=head3 bg_qx

=over 4

=item C<< $result = bg_qx $command >>

=item C<< $result = bg_qx $command, { option => value, ... } >>

=item C<< @result = bg_qx $command >>

=item C<< @result = bg_qx $command, { option => value, ... } >>

B<< API change since v0.43: In scalar context, the result is now
an overloaded object that retrieves its value when it is I<used> in
an expression. It is no longer a scalar I<reference> that retrieves
its value when it is I<dereferenced>. >>

Launches an external program and returns immediately. Execution of 
the command continues in a background process. When the command completes,
interprocess communication copies the output of the command into the
result (left hand side) variable. If the result variable is referenced
again before the background process is complete, the program will wait
until the background process completes.

Think of this command as a background version of Perl's backticks
or L<qx()|perlop/"qx"> function. In scalar context, the output of
the function will hold all the output produced by the command in
a single string. In list context, the output will be a list of the
lines produced by the command, however lines are defined by the
L<$/ or $RECORD_SEPARATOR|perlvar/"$RECORD_SEPARATOR"> variable.

The background job will be spawned with the C<Forks::Super::fork> call,
and the command can block, fail, or defer a background job in accordance
with all of the other rules of this module. Additional options may
be passed to C<bg_qx> that will be provided to the C<fork> call.
For example,

    $result = bg_qx "nslookup joe.schmoe.com", { timeout => 15 }

will run C<nslookup> in a background process for up to 15 seconds. 
The next time C<$result> is referenced in the program, it will
contain all of the output produced by the process up until the
time it was terminated. Most valid options for the C<fork> call
are also valid options for C<bg_qx>, including timeouts, delays,
job dependencies, names, and callbacks. The only invalid options 
for C<bg_qx> are L<"cmd">, L<"sub">, L<"exec">, and L<"child_fh">.

Like L<"bg_eval">, a call to C<bg_qx> will populate the
variables C<$Forks::Super::LAST_JOB> and C<$Forks::Super::LAST_JOB_ID>
with the L<Forks::Super::Job> object and the job id, respectively,
for the job created by the C<bg_qx> call. See L<MODULE VARIABLES/"LAST_JOB"> below.

See also: L<"bg_eval">.

=back

=head2 Miscellaneous functions

=head3 pause

=over 4

=item C<Forks::Super::pause($delay)>

A B<productive> drop-in replacement for the Perl L<sleep|perlfunc/"sleep">
system call (or L<Time::HiRes::sleep|Time::HiRes/"sleep">, if available). On
systems like Windows that lack a proper method for
handling C<SIGCHLD> events, the C<Forks::Super::pause> method
will occasionally reap child processes that have completed
and attempt to dispatch jobs on the queue.

On other systems, using C<Forks::Super::pause> is less vulnerable
than C<sleep> to interruptions from this module (See
L</"BUGS AND LIMITATIONS"> below).

=back

=head2 Obtaining job information

=head3 Forks::Super::Job::get

=over 4

=item C<$job = Forks::Super::Job::get($pid)>

Returns a C<Forks::Super::Job> object associated with process ID
or job ID C<$pid>. See L<Forks::Super::Job> for information about
the methods and attributes of these objects.

I<This subroutine is somewhat redundant since v0.41, where the
default return value of> C<fork> I<is an overloaded>
C<Forks::Super::Job> I<object instead of a simple scalar
process id>.

=back

=head3 Forks::Super::Job::getByName

=over 4

=item C<@jobs = Forks::Super::Job::getByName($name)>

Returns zero of more C<Forks::Super::Job> objects with the specified
job names. A job receives a name if a L<"name"> parameter was provided
in the C<Forks::Super::fork> call.

=back

=head3 state

=over 4

=item C<$state = Forks::Super::state($pid)>

Returns the state of the job specified by the given process ID,
job ID, or job name. See L<Forks::Super::Job/"state">.

=back

=head3 status

=over 4

=item C<$status = Forks::Super::status($pid)>

Returns the exit status of a completed child process
represented by process ID, job ID, or C<name> attribute.
Aside from being a permanent store of the exit status of a job,
using this method might be a more reliable indicator of a job's
status than checking C<$?> after a L<"wait"> or L<"waitpid"> call,
because it is possible for this module's C<SIGCHLD> handler
to temporarily corrupt the C<$?> value while it is checking
for deceased processes.

=back

=head1 MODULE VARIABLES

Module variables may be initialized on the C<use Forks::Super> line

    # set max simultaneous procs to 5, allow children to call CORE::fork()
    use Forks::Super MAX_PROC => 5, CHILD_FORK_OK => -1;

or they may be set explicitly in the code:

    $Forks::Super::ON_BUSY = 'queue';
    $Forks::Super::IPC_DIR = "/home/joe/temp-ipc-files";

Module variables that may be of interest include:

=head3 MAX_PROC

=over 4

=item C<$Forks::Super::MAX_PROC>

The maximum number of simultaneous background processes that can
be spawned by C<Forks::Super>. If a C<fork> call is attempted while
there are already at least this many active background processes,
the behavior of the C<fork> call will be determined by the
value in L<$Forks::Super::ON_BUSY|/"ON_BUSY"> or by the 
L<"on_busy"> option passed
to the C<fork> call.

This value will be ignored during a C<fork> call if the L<"force">
option is passed to C<fork> with a non-zero value. The value might also
not be respected if the user supplies a code reference in the
L<"can_launch"> option and the user-supplied code does not test
whether there are already too many active proceeses.

=back

=head3 ON_BUSY

=over 4

=item C<$Forks::Super::ON_BUSY = 'block' | 'fail' | 'queue'>

Determines behavior of a C<fork> call when the system is too
busy to create another background process.

If this value is set
to C<block>, then C<fork> will wait until the system is no
longer too busy and then launch the background process.
The return value will be a normal process ID value (assuming
there was no system error in creating a new process).

If the value is set to C<fail>, the C<fork> call will return
immediately without launching the background process. The return
value will be C<-1>. A C<Forks::Super::Job> object will not be
created.

If the value is set to C<queue>, then the C<fork> call
will create a "deferred" job that will be queued and run at
a later time. Also see the L<"queue_priority"> option to C<fork>
to set the urgency level of a job in case it is deferred.
The return value will be a large and negative
job ID.

This value will be ignored in favor of an L<"on_busy"> option
supplied to the C<fork> call.

=back

=head3 CHILD_FORK_OK

=over 4

=item C<$Forks::Super::CHILD_FORK_OK = -1 | 0 | +1>

Spawning a child process from another child process with this
module has its pitfalls, and this capability is disabled by
default: you will get a warning message and the C<fork()> call
will fail if you try it.

To override hits behavior, set C<$Forks::Super::CHILD_FORK_OK> to
a non-zero value. Setting it to a positive value will allow
you to use all the functionality of this module from a child
process (with the obvious caveat that you cannot C<wait> on the
child process of a child process from the main process).

Setting C<$Forks::Super::CHILD_FORK_OK> to a negative value will
disable the functionality of this module but will
reenable the classic Perl C<fork()> system call from child
processes.

Note that this module will not have any preconceptions about which
is the "parent process" until you the first 
call to C<Forks::Super::fork>. This means it is possible to use 
C<Forks::Super> functionality in processes that were I<not> 
spawned by C<Forks::Super>, say, by an explicit C<CORE::fork()> call:

     1: use Forks::Super;
     2: $Forks::Super::CHILD_FORK_OK = 0;
     3: 
     4: $child1 = CORE::fork();
     5: if ($child1 == 0) {
     6:    # OK -- child1 is still a valid "parent process"
     7:    $grandchild1 = Forks::Super::fork { ... };
     8:    ...;
     9:    exit;
    10: }
    11: $child2 = Forks::Super::fork();
    12: if ($child2 == 0) {
    13:    # NOT OK - parent of child2 is now "the parent"
    14:    $grandchild2 = Forks::Super::fork { ... };
    15:    ...; 
    16:    exit; 
    17: }
    18: $child3 = CORE::fork();
    19: if ($child3 == 0) {
    20:    # NOT OK - call in line 11 made parent of child3 "the parent"
    21:    $grandchild3 = Forks::Super::fork { ... };
    22:    ...; 
    23:    exit; 
    24: }

More specifically, this means it is OK to use the C<Forks::Super>
module in a daemon process:

    use Forks::Super;
    $Forks::Super::CHILD_FORK_OK = 0;
    CORE::fork() && exit;
    $daemon_child = Forks::Super::fork();   # ok

=back

=head3 DEBUG

=over 4

=item C<$Forks::Super::DEBUG, Forks::Super::DEBUG>

To see the internal workings of the C<Forks::Super> module, set
C<$Forks::Super::DEBUG> to a non-zero value. Information messages
will be written to the C<Forks::Super::Debug::DEBUG_fh> filehandle. By default
C<Forks::Super::Debug::DEBUG_fh> is aliased to C<STDERR>, but it may be reset
by the module user at any time.

Debugging behavior may be overridden for specific jobs
if the L<"debug"> or L<"undebug"> option is provided to C<fork>.

=back

=head3 %CHILD_STDxxx

=over 4

=item C<%Forks::Super::CHILD_STDIN>

=item C<%Forks::Super::CHILD_STDOUT>

=item C<%Forks::Super::CHILD_STDERR>

In jobs that request access to the child process filehandles,
these hash arrays contain filehandles to the standard input
and output streams of the child. The filehandles for particular
jobs may be looked up in these tables by process ID or job ID
for jobs that were deferred.

Remember that from the perspective of the parent process,
C<$Forks::Super::CHILD_STDIN{$pid}> is an output filehandle (what you
print to this filehandle can be read in the child's STDIN),
and C<$Forks::Super::CHILD_STDOUT{$pid}>
and C<$Forks::Super::CHILD_STDERR{$pid}>
are input filehandles (for reading what the child wrote
to STDOUT and STDERR).

As with any asynchronous communication scheme, you should
be aware of how to clear the EOF condition on filehandles
that are being simultaneously written to and read from by
different processes. A scheme like this works on most systems:

    # in parent, reading STDOUT of a child
    for (;;) {
        while (<{$Forks::Super::CHILD_STDOUT{$pid}}>) {
          print "Child $pid said: $_";
        }

        # EOF reached, but child may write more to filehandle later.
        sleep 1;
        seek $Forks::Super::CHILD_STDOUT{$pid}, 0, 1;
    }

The L<Forks::Super::Job|Forks::Super::Job> object provides the
methods C<write_stdin(@msg)>, C<read_stdout(\%options)>, and
C<read_stderr(\%options)> for object oriented read and write
operations to and from a child's IPC filehandles. These methods
can adjust their behavior based on the type of IPC channel
(file, socket, or pipe) or other idiosyncracies of your operating
system (#@$%^&*! Windows), B<so using those methods is preferred
to using the filehandles directly>.

=back

=head3 ALL_JOBS

=over 4

=item C<@Forks::Super::ALL_JOBS>

=item C<%Forks::Super::ALL_JOBS>

List of all C<Forks::Super::Job> objects that were created
from C<fork()> calls, including deferred and failed jobs.
Both process IDs and job IDs for jobs that were deferred at
one time) can be used to look up Job objects in the
C<%Forks::Super::ALL_JOBS> table.

=back

=head3 IPC_DIR

=over 4

=item C<$Forks::Super::IPC_DIR>

A directory where temporary files to be shared among processes
for interprocess communication (IPC) can be created. If not specified,
C<Forks::Super> will try to guess a good directory such as an
OS-appropriate temporary directory or your home directory as a
suitable store for these files.

C<$Forks::Super::IPC_DIR> is a tied variable and an
assignment to it will fail if the RHS is not suitable for
use as a temporary IPC file store.

C<Forks::Super> will look for the environment variable
C<IPC_DIR> and for an C<IPC_DIR> parameter on module import
(that is,

    use Forks::Super IPC_DIR => '/some/directory'

) for suggestions about where to store the IPC files.

Setting this value to C<undef> (the string literal C<"undef">,
not the Perl special value C<undef>) will disable 
file-based interprocess communication for your program. 
The module will fall back to using sockets or pipes 
(probably sockets) for all IPC.

=back

=head3 QUEUE_INTERRUPT

=over 4

=item C<$Forks::Super::QUEUE_INTERRUPT>

On systems with mostly-working signal frameworks, this
module installs a signal handler the first time that a
task is deferred. The signal that is trapped is
defined in the variable C<$Forks::Super::QUEUE_INTERRUPT>.
The default value is C<USR1>, and it may be overridden
directly or set on module import

    use Forks::Super QUEUE_INTERRUPT => 'TERM';
    $Forks::Super::QUEUE_INTERRUPT = 'USR2';

You would only worry about resetting this variable
if you (including other modules that you import) are
making use of an existing C<SIGUSR1> handler.

B<Since v0.40> this variable is generally not used unless

1. your system has a POSIX-y signal framework, and

2. L<Time::HiRes::setitimer|Time::HiRes/"setitimer"> 
is B<not> implemented for your system.

=back

=head3 TIMEOUT

=over 4

=item C<Forks::Super::TIMEOUT>

A possible return value from L<"wait"> and L<"waitpid">
functions when a timeout argument is supplied.
The value indicating a timeout should not collide with any other
possible value from those functions, and should be recognizable
as not an actual process ID.

    my $pid = wait 10.0;  # Forks::Super::wait with timeout
    if ($pid == Forks::Super::TIMEOUT) {
        # no tasks have finished in the last 10 seconds ...
    } else {
        # task has finished, process id in $pid.
    }

=back

=head3 LAST_JOB

=over 4

=item C<$Forks::Super::LAST_JOB_ID>

=item C<$Forks::Super::LAST_JOB>

Calls to the L<"bg_eval"> and L<"bg_qx"> functions launch
a background process and set the variables C<$Forks::Super::LAST_JOB_ID>
to the job's process ID and C<$Forks::Super::LAST_JOB> to the job's
L<Forks::Super::Job> object. These functions do not explicitly
return the job id, so these variables provide a convenient way
to query that state of the jobs launched by these functions.

Some C<bash> users will immediately recognize the parallels
between these variables and the special bash C<$!> variable, which
captures the process id of the last job to be run in the background.

=back

=head3 WAIT_ACTION_ON_SUSPENDED_JOBS

=over 4

=item C<$Forks::Super::Wait::WAIT_ACTION_ON_SUSPENDED_JOBS>

Governs the action of a call to L<"wait">, L<"waitpid">, or
L<"waitall"> in the case when all remaining jobs are in the
C<SUSPENDED> or C<DEFERRED-SUSPENDED> state (see
L<Forks::Super::Job/"state">). Allowable values for this variable
are

=over 4

=item C<wait>

Causes the call to L<"wait">/L<"waitpid"> to block indefinitely 
until those jobs start and one or more of them is completed. 
In this case it is presumed that the queue monitor is running periodically
and conditions that allow those jobs to get started will occur.
This is the default setting for this variable.

=item C<fail>

Causes the L<"wait">/L<"waitpid"> call to return with the special
(negative) value C<Forks::Super::Wait::ONLY_SUSPENDED_JOBS_LEFT>.

=item C<resume>

Causes one of the suspended jobs to be resumed. It is presumed
that this job will complete and allow the L<"wait">/L<"waitpid">
function to return.


=back

=back

=head1 EXPORTS

This module always exports the C<fork>, L<"wait">, L<"waitpid">, 
and L<"waitall"> functions, overloading the Perl system calls
with the same names. Mixing C<Forks::Super> calls with the
similarly-named Perl calls is strongly discouraged, but you
can access the original system calls at C<CORE::fork>,
C<CORE::wait>, etc.

Functions that can be exported to the caller's package include

    Forks::Super::bg_eval
    Forks::Super::bg_qx
    Forks::Super::isValidPid
    Forks::Super::pause
    Forks::Super::read_stderr
    Forks::Super::read_stdout

Module variables that can be exported are:

    %Forks::Super::CHILD_STDIN
    %Forks::Super::CHILD_STDOUT
    %Forks::Super::CHILD_STDERR

The special tag C<:var> will export all three of these hash tables
to the calling namespace.

The tag C<:all> will export all the functions and variables
listed above.

The C<Forks::Super::kill> function cannot be exported
for now, while I think through the implications of
overloading yet another Perl system call.

=head1 ENVIRONMENT

C<Forks::Super> makes use of the following optional variables
from your environment.

=over 4

=item FORKS_SUPER_DEBUG

If set, sets the default value of C<$Forks::Super::DEBUG>
(see L<"MODULE VARIABLES">) to true. 

=item FORKS_SUPER_QUEUE_DEBUG

If set and true, sends additional information about the
status of the queue (see L<"Deferred processes">) to 
standard output. This setting is independent of the
C<$ENV{FORKS_SUPER_DEBUG}>/C<$Forks::Super::DEBUG> setting.

=item FORKS_DONT_CLEANUP

If set and true, the program will not remove the temporary
files used for interprocess communication. This setting can
be helpful if you want to analyze the messages that were
sent between processes after the fact.

=item FORKS_SUPER_CONFIG

C<Forks::Super> will probe your system for available functions,
Perl modules, and external programs and try suitable workarounds
when the desired feature is not available. With
C<$ENV{FORKS_SUPER_CONFIG}>, you can command C<Forks::Super> to
assume that certain features are available (or are not available)
on your system. This is a little bit helpful for testing; I
don't know whether it would be helpful for anything else. 
See the source for C<Forks/Super/Config.pm> for more information
about how C<$ENV{FORKS_SUPER_CONFIG}> is used.

=item FORKS_SUPER_JOB_OVERLOAD

Specifies whether the C<fork> call will return an overloaded
L<Forks::Super::Job> object instead of a scalar process
identifier. See L<Forks::Super::Job/"OVERLOADING">. 
B<< Since v0.41 overloading is enabled by default. >>
If the C<FORKS_SUPER_JOB_OVERLOAD> variable is set, it will
override this default.

=item IPC_DIR

Specifies a directory for storing temporary files for 
interprocess communication. 
See L<"IPC_DIR" in "MODULE VARIABLES"|/"MODULE VARIABLES">.

=back

=head1 DIAGNOSTICS

=over 4

=item C<fork() not allowed in child process ...>

=item C<Forks::Super::fork() call not allowed in child process ...>

When the package variable C<$Forks::Super::CHILD_FORK_OK> is zero,
this package does not allow the C<fork()> method to be called from
a child process. Set
L<C<< $Forks::Super::CHILD_FORK_OK >>|/"CHILD_FORK_OK">
to change this behavior.

=item C<quick timeout>

A job was configured with a timeout/expiration time such that the
deadline for the job occurred before the job was even launched. The job
was killed immediately after it was spawned.

=item C<Job start/Job dependency E<lt>nnnE<gt> for job E<lt>nnnE<gt> is invalid. Ignoring.>

A process id or job id that was specified as a L<"depend_on"> 
or L<"depend_start">
option did not correspond to a known job.

=item C<Job E<lt>nnnE<gt> reaped before parent initialization.>

A child process finished quickly and was reaped by the parent
process C<SIGCHLD> handler before the parent process could even
finish initializing the job state. The state of the job in the
parent process might be unavailable or corrupt for a short time,
but eventually it should be all right.

=item C<interprocess filehandles not available>

=item C<could not open filehandle to provide child STDIN/STDOUT/STDERR>

=item C<child was not able to detect STDIN file ... Child may not have any input to read.>

=item C<could not open filehandle to write child STDIN>

=item C<could not open filehandle to read child STDOUT/STDERR>

Initialization of filehandles for a child process failed. The child process
will continue, but it will be unable to receive input from the parent through
the C<$Forks::Super::CHILD_STDIN{pid}> filehandle, or pass output to the
parent through the filehandles C<$Forks::Super::CHILD_STDOUT{PID}>
AND C<$Forks::Super::CHILD_STDERR{pid}>.

=item C<exec option used, timeout option ignored>

A C<fork> call was made using the incompatible options 
L<"exec"> and L<"timeout">.

=back

=head1 INCOMPATIBILITIES

This module requires its own C<SIGCHLD> handler,
and is incompatible with any module that tries to
install another C<SIGCHLD> handler. In particular,
if L<you are used to|perlfunc/"fork"> setting

    $SIG{CHLD} = 'IGNORE'

in your code, cut it out.

Some features use the L<alarm|perlfunc/"alarm"> function and custom
C<SIGALRM> handlers in the child processes. Using other
modules that employ this functionality may cause
undefined behavior. Systems and versions that do not
implement the C<alarm> function (like MSWin32 prior to
Perl v5.7) will not be able to use these features.

On some systems that (1) have a POSIX-y signal framework,
and (2) have B<not> implemented C<Time::HiRes::setitimer>,
this module will also try to install a C<SIGUSR1>
handler when there are deferred tasks. See the description
of C<$Forks::Super::QUEUE_INTERRUPT> under
L</"MODULE VARIABLES"> to use a different signal handler
if you intended to use a C<SIGUSR1> handler for
something else.

=head1 DEPENDENCIES

The L<Win32::API> module is required for Windows users.

The L<"bg_eval"> function requires either L<YAML>, L<YAML::Tiny>,
L<JSON>, or L<Data::Dumper>. If none of these modules are available, 
then using L<"bg_eval"> will result in a fatal error.

Otherwise, there are no hard dependencies on non-core 
modules. Some features, especially operating-system
specific functions, depend on some modules (L<Win32::Process>
and L<Win32> for Wintel systems, for example), but the module will
compile without those modules. Attempts to use these features
without the necessary modules will be silently ignored.

=head1 BUGS AND LIMITATIONS

=head2 Leftover temporary files and directories

In programs that use the interprocess communication features, 
the module will usually but not always do a good job of cleaning
up after itself. You may find directories called C<< .fhfork<nnn> >>
that may or not be empty scattered around your filesystem.

Invoking this module as one of

    $ perl -MForks::Super=cleanse
    $ perl -MForks::Super=cleanse,<directory>

runs a function that will clean up these directories. 

=cut

=head2 Interrupted system calls

A typical script using this module will have a lot of
behind-the-scenes signal handling as child processes
finish and are reaped. These frequent interruptions can
affect the execution of the rest of your program. 
For example, in this script:

    1: use Forks::Super;
    2: fork(sub => sub { sleep 2 });
    3: sleep 5;
    4: # ... program continues ...

the C<sleep> call in line 3 is probably going to get
interrupted before 5 seconds have elapsed as the end
of the child process spawned in line 2 will interrupt
execution and invoke the SIGCHLD handler.
In some cases there are tedious workarounds:

    3a: $stop_sleeping_at = time + 5;
    3b: sleep 1 while time < $stop_sleeping_at;

In this distribution, the L<Forks::Super::pause|/"pause">
call provides an interruption-resistant alternative to
C<sleep>. 

    3: Forks::Super::pause(5);

The C<pause> call itself has the limitation that it may
sleep for B<longer> than the desired time. This is because
the "productive" code executed in a C<pause> function
call can take an arbitrarily long time to run.

=head2 Idiosyncratic behavior on some systems

The system implementation of fork'ing and wait'ing varies
from platform to platform. This module has been extensively
tested on Cygwin, Windows, and Linux, but less so on other
systems. It is possible that some features will not work 
as advertised. Please report any problems you encounter 
to E<lt>mob@cpan.orgE<gt> and I'll see what I can do 
about it.

=head2 Segfaults during cleanup

On some systems, it has been observed that an application 
using the C<Forks::Super> module may run normally, but might
produce a segmentation fault or other error during cleanup.
This will cause the application to exit with a non-zero exit
code, even when the code accomplished everything it was 
supposed to. The cause and resolution of these errors is an
area of ongoing research.

=head2 Other bugs or feature requests

Feel free to report other bugs or feature requests
to C<bug-forks-super at rt.cpan.org> or through the
web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Forks-Super>.
This includes any cases where you think the documentation
might not be keeping up with the development.
I will be notified, and then you'll automatically be
notified of progress on your bug as I make changes.

=cut

=head1 SEE ALSO

There are reams of other modules on CPAN for managing background
processes. See Parallel::*, L<Proc::Parallel>, L<Proc::Fork>, 
L<Proc::Launcher>. Also L<Win32::Job>.

Inspiration for L<"bg_eval"> function from L<Acme::Fork::Lazy>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2011, Marty O'Brien.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

See http://dev.perl.org/licenses/ for more information.

=cut

TODO in future releases: See TODO file.
