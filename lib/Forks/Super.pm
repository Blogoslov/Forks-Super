package Forks::Super;
use 5.007003;     # for "safe" signals -- see perlipc
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
use base 'Exporter';
use POSIX ':sys_wait_h';
use Carp;
use strict;
use warnings;
$| = 1;

{
  no warnings 'once';
  $Carp::Internal{ (__PACKAGE__) }++;
}

our $VERSION = '0.35';

our @EXPORT = qw(fork wait waitall waitpid);
my @export_ok_func = qw(isValidPid pause Time read_stdout read_stderr
			bg_eval bg_qx open2 open3);
my @export_ok_vars = qw(%CHILD_STDOUT %CHILD_STDERR %CHILD_STDIN);
our @EXPORT_OK = (@export_ok_func, @export_ok_vars);
our %EXPORT_TAGS = 
  ( 'test' =>  [ qw(isValidPid Time bg_eval bg_qx), @EXPORT ],
    'test_config' =>  [ qw(isValidPid Time bg_eval bg_qx), @EXPORT ],
    'filehandles' => [ @export_ok_vars, @EXPORT ],
    'vars' => [ @export_ok_vars, @EXPORT ],
    'all' => [ @EXPORT_OK, @EXPORT ] );

our $SOCKET_READ_TIMEOUT = 1.0;
our ($MAIN_PID, $ON_BUSY, $MAX_PROC, $MAX_LOAD, $DEFAULT_MAX_PROC);
our ($DONT_CLEANUP, $CHILD_FORK_OK, $QUEUE_INTERRUPT, $PKG_INITIALIZED);
our (%IMPORT, $LAST_JOB, $LAST_JOB_ID, %BASTARD_DATA, $SUPPORT_LIST_CONTEXT);

sub import {
  my ($class,@args) = @_;
  my @tags;
  _init();
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
    } elsif ($args[$i] eq 'FH_DIR') {
      my $dir = $args[++$i];
      if ($dir =~ /\S/ && -d $dir && -r $dir && -w $dir && -x $dir) {
	Forks::Super::Job::Ipc::_set_fh_dir($dir);
      } else {
	carp "Forks::Super: Invalid FH_DIR value \"$dir\": $!\n";
      }
    } elsif (uc $args[$i] eq 'OVERLOAD') {
      Forks::Super::Job::enable_overload();
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
	Forks::Super::Job::Timeout::warm_up();
      }
    }
  }

  $IMPORT{$_}++ foreach @tags;
  Forks::Super->export_to_level(1, "Forks::Super", @tags?@tags:@EXPORT);
  return;
}

sub _init {
  return if $PKG_INITIALIZED;
  $PKG_INITIALIZED++;
  # $MAIN_PID = $$;     # set on first use

  Forks::Super::Debug::init();
  Forks::Super::Config::init();

  # Default value for $MAX_PROC should be tied to system properties
  $DEFAULT_MAX_PROC = $Forks::Super::SysInfo::MAX_FORK - 1;
  $MAX_PROC = $DEFAULT_MAX_PROC;
  $MAX_LOAD = -1;
  $SUPPORT_LIST_CONTEXT = 0;

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

  Forks::Super::Queue::init();

  $SIG{CHLD} = \&Forks::Super::Sigchld::handle_CHLD;
  return;
}

sub fork {
  my ($opts) = @_;
  if (ref $opts ne 'HASH') {
    $opts = { @_ };
  }

  $MAIN_PID ||= $$;
  my $job = Forks::Super::Job->new($opts);
  $job->_preconfig;
  if (defined $job->{__test}) {
    return $Forks::Super::SUPPORT_LIST_CONTEXT && wantarray ? ($job->{__test}, $job) : $job->{__test};
  }

  debug('fork(): ', $job->toString(), ' initialized.')
    if $job->{debug};

  until ($job->can_launch) {

    debug("fork(): job can not launch. Behavior=$job->{_on_busy}")
      if $job->{debug};

    if ($job->{_on_busy} eq 'FAIL') {
      $job->run_callback('fail');

      #$job->_mark_complete;
      $job->{end} = Forks::Super::Util::Time();

      $job->{status} = -1;
      $job->_mark_reaped;
      return $Forks::Super::SUPPORT_LIST_CONTEXT && wantarray ? (-1) : -1;
    } elsif ($job->{_on_busy} eq 'QUEUE') {
      $job->run_callback('queue');
      $job->queue_job;
      if ($Forks::Super::Job::OVERLOAD_ENABLED) {
	if ($Forks::Super::SUPPORT_LIST_CONTEXT && wantarray) {
	  return ($job,$job);
	} else {
	  return $job;
	}
      } elsif ($Forks::Super::SUPPORT_LIST_CONTEXT && wantarray) {
	return ($job->{pid}, $job);
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
  $SIG{CHLD} = $SIG{CLD} = 'DEFAULT';

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
  return Forks::Super::Job::read_stdout($job);
}

#
# like read_stdout() but for stderr.
#
sub read_stderr {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  return Forks::Super::Job::read_stderr($job);
}

sub close_fh {
  my $pid_or_job = shift;
  if (Forks::Super::Job::_resolve($pid_or_job)) {
    $pid_or_job->close_fh;
  }
}

######################################################################


sub kill {
  my ($signal, @jobs) = @_;
  my $kill_proc_group = $signal =~ s/^-//;
  my $num_signalled = 0;
  my $run_queue_needed = 0;
  if ($signal !~ /\D/) {
    # convert to canonical signal name.
    $signal = Forks::Super::Util::signal_name($signal);
  }
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
    foreach my $j (@deferred_jobs) {
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

  if (@pids > 0) {

    if (&IS_WIN32) {

      # preferred way to kill a MSWin32 pseudo-process
      # is with the Win32 API "TerminateThread". Using Perl's kill
      # usually doesn't work

      foreach my $pid (sort {$a <=> $b} @pids) {
	if ($pid < 0) {
	  local $! = 0;
	  my $signalled = 0;

	  if (Forks::Super::Util::is_kill_signal($signal)) {
	    if (Forks::Super::Job::OS::Win32::terminate_thread(-$pid)) {
	      $signalled = 1;
	      $num_signalled++;;
	      push @terminated, $pid;
	    }
	  } elsif ($signal eq 'STOP') {
	    if (Forks::Super::Job::OS::Win32::suspend_thread(-$pid)) {
	      $signalled = 1;
	      $num_signalled++;
	    }
	  } elsif ($signal eq 'CONT') {
	    if (Forks::Super::Job::OS::Win32::resume_thread(-$pid)) {
	      $signalled = 1;
	      $num_signalled++;
	    }
	  } else {
	    carp_once [$signal], "Forks::Super::kill(): ",
	      "Called on MSWin32 with SIG$signal\n",
	      "Ignored because this module can't find a suitable way to\n",
	      "express that signal on MSWin32.\n";
	  }

	  if (!$signalled) {
	    if (!CONFIG('Win32::API')) {
	      carp_once "Using potentially unsafe kill() command ",
		"on MSWin32 psuedo-process.\n",
		"Install Win32::API module for a safer alternative.\n";
	    }
	    local $! = 0;
	    $num_signalled += CORE::kill($kill_proc_group 
					 ? -$signal : $signal, $pid);
	    carp "MSWin32 kill error $! $^E\n" if $!;
	  }
	} else {
	  $num_signalled += CORE::kill($kill_proc_group 
				       ? -$signal : $signal, $pid);
        }
      }
    } elsif (@pids > 0) {
      local $! = 0;
      if (Forks::Super::Util::is_kill_signal($signal)) {
	foreach my $pid (@pids) {
	  $! = 0;
	  if (CORE::kill $signal, $pid) {
	    $num_signalled++;
	    push @terminated, $pid;
	  }
	  if ($!) {
	    carp "kill error $! $^E\n";
	  }
	}
      } else {
	$num_signalled += CORE::kill $signal, @pids;
	if ($!) {
	  carp "kill error $! $^E\n";
	}
      }
    }
  }

  if (@terminated > 0) {
    my $old_status = $?;
    foreach my $pid (@terminated) {
      if ($pid == waitpid $pid, 0, 1.0) {
	# unreap.
	my $j = Forks::Super::Job::get($pid);
	$j->{state} = 'COMPLETE';
	delete $j->{reaped};
	$? = $old_status;
      }
    }
  }

  if ($run_queue_needed) {
    Forks::Super::Queue::check_queue();
  }
  return $num_signalled;
}

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
  my $pid = Forks::Super::fork( $options );
  if (!defined $pid) {
    return;
  }
  my $input = $Forks::Super::CHILD_STDIN{$pid};
  my $output = $Forks::Super::CHILD_STDOUT{$pid};
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
  $BASTARD_DATA{$pid} = [ Forks::Super::Util::Time(), $status ];
  return;
}

sub _set_last_job {
  my ($job, $id) = @_;
  $LAST_JOB = $job;
  $LAST_JOB_ID = $id;
  return;
}

sub _is_test {
  return defined $IMPORT{':test'} && $IMPORT{':test'};
}

1;

__END__

------------------------------------------------------------------------------

=head1 NAME

Forks::Super - extensions and convenience methods 
for managing background processes.

=head1 VERSION

Version 0.35

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
    $pid = fork { cmd => $command, timeout => 30 };            # kill child if not done in 30s
    $pid = fork { sub => $subRef , expiration => 1260000000 }; # complete by 8AM Dec 5, 2009 UTC

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
    $child_response = <$child_stdout>; # -or-  = Forks::Super::read_stdout($pid);
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
    # runs 100 tasks but the fork call blocks when there are already 5 jobs running
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

    # $Forks::Super::MAX_PROC setting can be overridden. Start job immediately if < 3 jobs running
    $pid = fork { sub => 'MyModule::MyMethod', args => [ @b ], max_proc => 3 };

    # try to fork no matter how busy the system is
    $pid = fork { force => 1, sub => \&MyMethod, args => [ @my_args ] };

    # when system is busy, queue jobs. When system is not busy, some jobs on the queue will start.
    # if job is queued, return value from fork() is a very negative number
    $Forks::Super::ON_BUSY = 'queue';
    $pid = fork { cmd => $command };
    $pid = fork { cmd => $useless_command, queue_priority => -5 };
    $pid = fork { cmd => $important_command, queue_priority => 5 };
    $pid = fork { cmd => $future_job, delay => 20 }   # keep job on queue for at least 20s

    # assign descriptive names to tasks
    $pid1 = fork { cmd => $command, name => "my task" };
    $pid2 = waitpid "my task", 0;

    # run callbacks at various points of job life-cycle
    $pid = fork { cmd => $command, callback => \&on_complete };
    $pid = fork { sub => $sub, callback => { start => 'on_start', finish => \&on_complete,
                                             queue => sub { print "Job $_[1] queued.\n" } } };

    # set up dependency relationships
    $pid1 = fork { cmd => $job1 };
    $pid2 = fork { cmd => $job2, depend_on => $pid1 };            # put on queue until job 1 is complete
    $pid4 = fork { cmd => $job4, depend_start => [$pid2,$pid3] }; # put on queue until jobs 2,3 have started

    $pid5 = fork { cmd => $job5, name => "group C" };
    $pid6 = fork { cmd => $job6, name => "group C" };
    $pid7 = fork { cmd => $job7, depend_on => "group C" }; # wait for jobs 5 & 6 to complete

    # manage OS settings on jobs -- not available on all systems
    $pid1 = fork { os_priority => 10 };    # like nice(1) on Un*x
    $pid2 = fork { cpu_affinity => 0x5 };  # background task will prefer CPUs #0 and #2

    # job information
    $state = Forks::Super::state($pid);    # 'ACTIVE', 'DEFERRED', 'COMPLETE', 'REAPED'
    $status = Forks::Super::status($pid);  # exit status for completed jobs

    # --- evaluate long running expressions in the background
    $result = bg_eval { a_long_running_calculation() };
    # sometime later ...
    print "Result was $$result\n";

    @result = bg_qx( "./long_running_command" );
    # ... do something else for a while and when you need the output ...
    print "output of long running command was: @result\n";

    # --- convenience methods, compare to IPC::Open2, IPC::Open3
    my ($fh_in, $fh_out, $pid, $job) = Forks::Super::open2(@command);
    my ($fh_in, $fh_out, $fh_err, $pid, $job) = Forks::Super::open3(@command, { timeout => 60 });

=head1 DESCRIPTION

This package provides new definitions for the Perl functions
C<fork>, C<wait>, and C<waitpid> with richer functionality.
The new features are designed to make it more convenient to
spawn background processes and more convenient to manage them
to get the most out of your system's resources.

=head1 C<$pid = fork( \%options )>

The new C<fork> call attempts to spawn a new process.
With no arguments, it behaves the same as the Perl
L<< fork()|perlfunc/fork >> system call.

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

The C<fork> call supports three options, C<cmd>, C<exec>,
and C<sub> (or C<sub>/C<args>)
that will instruct the child process to carry out a specific task.
Using any of these options causes the child process not to
return from the C<fork> call.

=over 4

=item C<< $child_pid = fork { cmd => $shell_command } >>

=item C<< $child_pid = fork { cmd => \@shell_command } >>

On successful launch of the child process, runs the specified
shell command in the child process with the Perl C<system()>
function. When the system call is complete, the child process
exits with the same exit status that was returned by the system call.

Returns the PID of the child process to
the parent process. Does not return from the child process, so you
do not need to check the fork() return value to determine whether
code is executing in the parent or child process.

=back

=over 4

=item C<< $child_pid = fork { exec => $shell_command } >>

=item C<< $child_pid = fork { exec => \@shell_command } >>

Like the C<cmd> option, but the background process launches the
shell command with C<exec> instead of with C<system>.

Using C<exec> instead of C<cmd> will spawn one fewer process,
but note that the C<timeout> and C<expiration> options cannot
be used with the C<exec> option (see
L<"Options for simple job management">).

=back

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

If neither the C<cmd>, C<exec>, nor the C<sub> option is provided 
to the fork call, then the fork() call behaves like a standard
Perl C<fork()> call, returning the child PID to the parent and also 
returning zero to a new child process.

As of v0.34, the C<fork> function can return an overloaded
L<Forks::Super::Job> object to the parent process instead of
a simple scalar representing the job ID. When this feature is
enabled, the return value will behave like the simple scalar
in any numerical context but the attributes and methods of
C<Forks::Super::Job> will also be available. B<This feature
is not enabled by default in v0.34>. See 
L<Forks::Super::Job/"OVERLOADING"> for more details including
how to enable this feature.

=back

=head2 Options for simple job management

=over 4

=item C<< fork { timeout => $delay_in_seconds } >>

=item C<< fork { expiration => $timestamp_in_seconds_since_epoch_time } >>

Puts a deadline on the child process and causes the child to C<die>
if it has not completed by the deadline. With the C<timeout> option,
you specify that the child process should not survive longer than the
specified number of seconds. With C<expiration>, you are specifying
an epoch time (like the one returned by the C<time> function) as the
child process's deadline.

If the C<setpgrp()> system call is implemented on your system,
then this module will try to reset the process group ID of the child
process. On timeout, the module will attempt to kill off all
subprocesses of the expiring child process.

If the deadline is some time in the past (if the timeout is
not positive, or the expiration is earlier than the current time),
then the child process will die immediately after it is created.

Note that this feature uses the Perl C<alarm> call with a
handler for C<SIGALRM>. If you use this feature and also specify a
C<sub> to invoke, and that subroutine also tries to use the
C<alarm> feature or set a handler for C<SIGALRM>, the results
will be undefined.

The C<timeout> and C<expiration> options cannot be used with the
C<exec> option, since the child process will not be able to
generate a C<SIGALRM> after an C<exec> call.

=item C<< fork { delay => $delay_in_seconds } >>

=item C<< fork { start_after => $timestamp_in_epoch_time } >>

Causes the child process to be spawned at some time in the future.
The return value from a C<fork> call that uses these features
will not be a process id, but it will be a very negative number
called a job ID. See the section on L</"Deferred processes">
for information on what to do with a job ID.

A deferred job will start B<no earlier> than its appointed time
in the future. Depending on what circumstances the queued jobs
are examined, B<the actual start time of the job could be significantly
later than the appointed time>.

A job may have both a minimum start time (through C<delay> or
C<start_after> options) and a maximum end time (through
C<timeout> and C<expiration>). Jobs with inconsistent times
(end time is not later than start time) will be killed of
as soon as they are created.

=item C<< fork { child_fh => $fh_spec } >>

=item C<< fork { child_fh => [ @fh_spec ] } >>

B<Note: API change since v0.10.>

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
C<join>, C<all>, or C<socket>.

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

I<The> C<system-limits> I<file that was created in your
build directory will have information about the socket and
pipe capacity of your system, if you are interested.>

=item *

On Windows, sockets and pipes are blocking, and care must be taken
to prevent your script from reading on an empty socket

=back

=cut

=head3 Socket and file handle gotchas

Some things to keep in mind when using socket or file handles
to communicate with a child process.

=over 4

=item *

care should be taken before C<close>'ing a socket handle.
The same socket handle can be used for both reading and writing.
Don't close a handle when you are only done with one half of the
socket operations.

=item *

The test C<Forks::Super::Util::is_socket($handle)> can determine
whether C<$handle> is a socket handle or a regular filehandle.
The test C<Forks::Super::Util::is_pipe($handle)> 
can determine whether C<$handle> is reading from or writing to a pipe.

=item *

The following idiom is safe to use on both socket handles, pipes,
and regular filehandles:

    shutdown($handle,2) || close $handle;

=cut

Is this true?  shutdown  "is a more insistent form of close
because it also disables the file descriptor in any forked
copies in other processes." 

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

=over 4

=item C<< fork { stdin => $input } >>

Provides the data in C<$input> as the child process's standard input.
Equivalent to, but a little more efficient than:

    $pid = fork { child_fh => "in", sub => sub { ... } };
    print {$Forks::Super::CHILD_STDIN{$pid}} $input;

C<$input> may either be a scalar, a reference to a scalar, or
a reference to an array.

=item C<< fork { stdout => \$output } >>

=item C<< fork { stderr => \$errput } >>

On completion of the background process, loads the standard output
and standard error of the child process into the given scalar
references. If you do not need to use the child's output while
the child is running, it could be more convenient to use this
construction than calling C<Forks::Super::read_stdout($pid)>
(or C<< <{$Forks::Super::CHILD_STDOUT{$pid}}> >>) to obtain
the child's output.

=item C<< fork { retries => $max_retries } >>

If the underlying system C<fork> call fails (i.e., returns
C<undef>), pauses for a short time and retries up to
C<$max_retries> times.

This feature is probably not that useful, as a failed
C<fork> call usually indicates some bad system condition
(too many processes, system out of memory or swap space,
impending kernel panic, etc.). In such a case, your 
expectations of recovery should not be too high.

=back

=head2 Options for complicated job management

The C<fork()> call from this module supports options that help to
manage child processes or groups of child processes in ways to better
manage your system's resources. For example, you may have a lot of
tasks to perform in the background, but you don't want to overwhelm
your (possibly shared) system by running them all at once. There
are features to control how many, how, and when your jobs will run.

=over 4

=head3 name

=item C<< fork { name => $name } >>

Attaches a string identifier to the job. The identifier can be used
for several purposes:

=over 4

=item * to obtain a L<Forks::Super::Job> object representing the
background task through the C<Forks::Super::Job::get> or
C<Forks::Super::Job::getByName> methods.

=item * as the first argument to C<waitpid> to wait on a job or jobs
with specific names

=item * to identify and establish dependencies between background
tasks. See the C<depend_on> and C<depend_start> parameters below.

=item * if supported by your system, the name attribute will change
the argument area used by the ps(1) program and change the
way the background process is displaying in your process viewer.
(See L<$PROGRAM_NAME in perlvar|perlvar/"$PROGRAM_NAME">
about overriding the special C<$0> variable.)

=back

=item C<$Forks::Super::MAX_PROC = $max_simultaneous_jobs>

=item C<< fork { max_fork => $max_simultaneous_jobs } >>

Specifies the maximum number of background processes that you want
to run. If a C<fork> call is attempted while there are already
the maximum number of child processes running, then the C<fork()>
call will either block (until some child processes complete),
fail (return a negative value without spawning the child process),
or queue the job (returning a very negative value called a job ID),
according to the specified "on_busy" behavior (see the next item).
See the L</"Deferred processes"> section for information about
how queued jobs are handled.

On any individual C<fork> call, the maximum number of processes may be
overridden by also specifying C<max_proc> or C<force> options.

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

If your system does not have a well-behaved C<uptime(1)>
command, then you may need to install the C<Sys::CpuLoadX>
module to use this feature. For now, the C<Sys::CpuLoadX>
module is only available bundled with C<Forks::Super> and
otherwise cannot be downloaded from CPAN.

=item C<$Forks::Super::ON_BUSY = "block" | "fail" | "queue">

=item C<< fork { on_busy => "block" | "fail" | "queue" } >>

Dictates the behavior of C<fork> in the event that the module is not allowed
to launch the specified job for whatever reason.

=over 4

=item C<block>

If the system cannot create a new child process for the specified job,
it will wait and periodically retry to create the child process until
it is successful. Unless a system fork call is attempted and fails,
C<fork> calls that use this behavior will return a positive PID.

=item C<fail>

If the system cannot create a new child process for the specified job,
the C<fork> call will immediately return with a small negative
value.

=item C<queue>

If the system cannot create a new child process for the specified job,
the job will be deferred, and an attempt will be made to launch the
job at a later time. See L</"Deferred processes"> below. The return
value will be a very negative number (job ID).

=back

On any individual C<fork> call, the default launch failure behavior specified
by C<$Forks::Super::ON_BUSY> can be overridden by specifying a
C<on_busy> option:

    $Forks::Super::ON_BUSY = "fail";
    $pid1 = fork { sub => 'myMethod' };
    $pid2 = fork { sub => 'yourMethod', on_busy => "queue" }

=item C<< fork { force => $bool } >>

If the C<force> option is set, the C<fork> call will disregard the
usual criteria for deciding whether a job can spawn a child process,
and will always attempt to create the child process.

=item C<< fork { queue_priority => $priority } >>

In the event that a job cannot immediately create a child process and
is put on the job queue (see L</"Deferred processes">), the C{queue_priority}
specifies the relative priority of the job on the job queue. In general,
eligible jobs with high priority values will be started before jobs
with lower priority values.

=item C<< fork { depend_on => $id } >>

=item C<< fork { depend_on => [ $id_1, $id_2, ... ] } >>

=item C<< fork { depend_start => $id } >>

=item C<< fork { depend_start => [ $id_1, $id_2, ... ] } >>

Indicates a dependency relationship between the job in this C<fork>
call and one or more other jobs. The identifiers may be
process/job IDs or C<name> attributes (ses above) from
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
if the job is deferred for any reason (see L</"Deferred processes">) and
the job is placed onto the job queue for the first time. And the C<fail>
callback is run if the job is not going to be launched (that is, a case
where the C<fork> call would return C<-1>).

Callbacks are invoked with two arguments:
the C<Forks::Super::Job> object that was created with the original
C<fork> call, and the job's ID (the return value from C<fork>).

You should keep your callback functions short and sweet, like you do
for your signal handlers. Sometimes callbacks are invoked from the
signal handler, and the processing of other signals could be
delayed if the callback functions take too long to run.

=head3 suspend

=item C<< fork { suspend => 'subroutineName' } } >>

=item C<< fork { suspend => \&subroutineName } } >>

=item C<< fork { suspend => sub { ... anonymous sub ... } } >>

Registers a callback function that can indicate when a background
process should be suspended and when it should be resumed.
The callback function will receive one argument -- the
L<Forks::Super::Job> object that owns the callback -- and is
expected to return a numerical value. The callback function
will be evaluated periodically (for example, during the
productive downtime of a C<wait>/C<waitpid> call or
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



=item C<< fork { os_priority => $priority } >>

On supported operating systems, and after the successful creation
of the child process, attempt to set the operating system priority
of the child process, using your operating system's notion of
what priority is.

On unsupported systems, this option is ignored.

=item C<< fork { cpu_affinity => $bitmask } >>

On supported operating systems with multiple cores,
and after the successful creation of the child process,
attempt to set the child process's CPU affinity.
Each bit of the bitmask represents one processor. Set a bit to 1
to allow the process to use the corresponding processor, and set it to
0 to disallow the corresponding processor. There may be additional
restrictions on the valid range of values imposed by the operating
system.

This feature requires the L<Sys::CpuAffinity> module. The
C<Sys::CpuAffinity> module is bundled with C<Forks::Super>,
or it may be obtained from CPAN.

=item C<< fork { debug => $bool } >>

=item C<< fork { undebug => $bool } >>

Overrides the value in C<$Forks::Super::DEBUG> (see L</"MODULE VARIABLES">)
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
it may be used like a PID as an argument to C<waitpid>,
as a dependency specification in another C<fork> call's
C<depend_on> or C<depend_start> option, or
the other module methods used to retrieve job information
(See L</"Obtaining job information"> below). Once a deferred
job has been started, it will be possible to obtain the
actual PID (or on Windows, the actual
psuedo-process ID) of the process running that job.

=head3 Job priority

Every job on the queue will have a priority value. A job's
priority may be set explicitly by including the
C<queue_priority> option in the C<fork()> call, or it will
be assigned a default priority near zero. Every time the
queue is examined, the queue will be sorted by this priority
value and an attempt will be made to launch each job in this
order. Note that different jobs may have different criteria
for being launched, and it is possible that that an eligible
low priority job may be started before an ineligible
higher priority job.

=head3 Queue examination

Certain events in the C<SIGCHLD> handler or in the
C<wait>, C<waitpid>, and/or C<waitall> methods will cause
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

=over 4

=head3 wait

=item C<$reaped_pid = wait [$timeout] >

Like the Perl L<< wait|perlfunc/wait >> system call,
blocks until a child process
terminates and returns the PID of the deceased process,
or C<-1> if there are no child processes remaining to reap.
The exit status of the child is returned in C<$?>.

This version of the C<wait> call can take an optional
C<$timeout> argument, which specifies the maximum length of
time in seconds to wait for a process to complete.
If a timeout is supplied and no process completes before the
timeout expires, then the C<wait> function returns the
value C<-1.5> (you can also test if the return value of the
function is the same as C<Forks::Super::TIMEOUT>, which
is a constant to indicate that a wait call timed out).

If C<wait> (or C<waitpid> or C<waitall>) is called when
all jobs are either complete or suspended, and there is
at least one suspended job, then the behavior is
governed by the setting of the L<<
$Forks::Super::WAIT_ACTION_ON_SUSPENDED_JOBS|/"WAIT_ACTION_ON_SUSPENDED_JOBS"
>> variable.

=head3 waitpid

=item C<$reaped_pid = waitpid $pid, $flags [, $timeout] >

Waits for a child with a particular PID or a child from
a particular process group to terminate and returns the
PID of the deceased process, or C<-1> if there is no
suitable child process to reap. If the return value contains
a PID, then C<$?> is set to the exit status of that process.

A valid job ID (see L</"Deferred processes">) may be used
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

If the optional C<$timeout> argument is provided, the C<waitall>
function will block for at most C<$timeout> seconds, and
return C<-1.5> (or C<Forks::Super::TIMEOUT> if a suitable
process is not reaped in that time.

=cut

=head3 waitall

=item C<$count = waitall [$timeout] >

Blocking wait for all child processes, including deferred
jobs that have not started at the time of the C<waitall>
call. Return value is the number of processes that were
waited on.

If the optional C<$timeout> argument is supplied, the
function will block for at most C<$timeout> seconds before
returning.

=head3 kill

=item C<$num_signalled = Forks::Super::kill $signal, @jobsOrPids>

Send a signal to the background processes specified
either by process IDs, job names, or C<Forks::Super::Job>
objects. Returns the number of jobs that were successfully
signalled.

This method "does what you mean" with respect to terminating,
suspending, or resuming processes. In this way, jobs in the
job queue (that don't even have a proper PID) may still be
"signalled". On Windows systems, which do not have a Unix-like
signals framework, this can be accomplished through 
the appropriate Windows API calls. It is highly recommended
that you install the L<Win32::API> module for this purpose.

On Windows, which does not have a Unix-like signals framework,
this method will sometimes "do what you mean" with respect
to suspending, resuming, and terminating processes through
other Windows API calls. It is highly recommended that you
install the L<Win32::API> module for this purpose.

See also the L<< 
Forks::Super::Job::suspend|Forks::Super::Job/"$job->suspend" >>
and L<< resume|Forks::Super::Job/"$job->resume" >> methods. It is
preferable (out of portability concerns) to use these methods

    $job->suspend;
    $job->resume;

rather than C<Forks::Super::kill>.

    Forks::Super::kill 'STOP', $job;
    Forks::Super::kill 'CONT', $job;

=head3 kill_all

=item C<$num_signalled = Forks::Super::kill_all $signal>

Sends a "signal" (see expanded meaning of "signal" in
L</"kill">, above). to all relevant processes spawned from the
C<Forks::Super> module. 

=head3 isValidPid

=item C<Forks::Super::isValidPid( $pid )>

Tests whether the return value of a C<fork> call indicates that
a background process was successfully created or not. On POSIX
systems it is sufficient to check whether C<$pid> is a
positive integer, but C<isValidPid> is a more

=head3 pause

=item C<Forks::Super::pause($delay)>

A B<productive> drop-in replacement for the Perl C<sleep>
system call (or C<Time::HiRes::sleep>, if available). On
systems like Windows that lack a proper method for
handling C<SIGCHLD> events, the C<Forks::Super::pause> method
will occasionally reap child processes that have completed
and attempt to dispatch jobs on the queue.

On other systems, using C<Forks::Super::pause> is less vulnerable
than C<sleep> to interruptions from this module (See
L</"BUGS AND LIMITATIONS"> below).

=head3 status

=item C<$status = Forks::Super::status($pid)>

Returns the exit status of a completed child process
represented by process ID, job ID, or C<name> attribute.
Aside from being a permanent store of the exit status of a job,
using this method might be a more reliable indicator of a job's
status than checking C<$?> after a C<wait> or C<waitpid> call,
because it is possible for this module's C<SIGCHLD> handler
to temporarily corrupt the C<$?> value while it is checking
for deceased processes.

=head3 read_stdout

=head3 read_stderr

=item C<$line = Forks::Super::read_stdout($pid)>

=item C<@lines = Forks::Super::read_stdout($pid)>

=item C<$line = Forks::Super::read_stderr($pid)>

=item C<@lines = Forks::Super::read_stderr($pid)>

For jobs that were started with the C<< child_fh => "out" >>
and C<< child_fh => "err" >> options enabled, read data from
the STDOUT and STDERR filehandles of child processes.

Aside from the more readable syntax, these functions may be preferable to

    @lines = < {$Forks::Super::CHILD_STDOUT{$pid}} >;
    $line = < {$Forks::Super::CHILD_STDERR{$pid}} >;

because they will automatically handle clearing the EOF condition
on the filehandles if the parent is reading on the filehandles faster
than the child is writing on them.

Functions work in both scalar and list context. If there is no data to
read on the filehandle, but the child process is still active and could
put more data on the filehandle, these functions return  ""  in scalar
and list context. If there is no more data on the filehandle and the
child process is finished, the functions return C<undef>.

=head3 close_fh

=item C<Forks::Super::close_fh($pid)>

Closes all open file handles and socket handles for interprocess communication
with the specified child process. Most operating systems impose a hard limit
on the number of filehandles that can be opened in a process simultaneously,
so you should use this function when you are finished communicating with
a child process so that you don't run into that limit.

=head3 open2

=item C< ($in,$out,$pid,$job) = Forks::Super::open2( @command [, \%options ] )>

=head3 open3

=item C< ($in,$out,$err,$pid,$job) = Forks::Super::open3( @command [, \%options] )>

Starts a background process and returns filehandles to the process's
standard input and standard output (and standard error in the case
of the C<open3> call). Also returns the process id and the
L<Forks::Super::Job> object associated with the background process.

Compare these methods to the main functions of the L<IPC::Open2> and L<IPC::Open3>
modules.

Many of the options that can be passed to C<Forks::Super::fork> can also
be passed to C<Forks::Super::open2> and C<Forks::Super::open3>:

    # run a command but kill it after 30 seconds
    ($in,$out,$pid) = Forks::Super::open2("ssh me\@mycomputer ./runCommand.sh", { timeout => 30 });

    # invoke a callback when command ends
    ($in,$out,$err,$pid,$job) = Forks::Super::open3(@cmd, {callback => sub { print "\@cmd finished!\n" }});

=back

=head3 Obtaining job information

=over 4

=item C<$job = Forks::Super::Job::get($pid)>

Returns a C<Forks::Super::Job> object associated with process ID
or job ID C<$pid>. See L<Forks::Super::Job> for information about
the methods and attributes of these objects.

=item C<@jobs = Forks::Super::Job::getByName($name)>

Returns zero of more C<Forks::Super::Job> objects with the specified
job names. A job receives a name if a C<name> parameter was provided
in the C<Forks::Super::fork> call.

=head3 state

=item C<$state = Forks::Super::state($pid)>

Returns the state of the job specified by the given process ID,
job ID, or job name. See L<Forks::Super::Job/"state">.

=head3 status

=item C<$status = Forks::Super::status($pid)>

Returns the exit status of the job specified by the given
process ID, job ID, or job name. See L<Forks::Super::Job/"status">.
This value will be undefined until the job is complete.

=head3 bg_eval

=item C<< $reference = bg_eval { BLOCK } >>

=item C<< $reference = bg_eval { BLOCK } { option => value, ... } >>

Evaluates the specified block of code in a background process. When the
parent process dereferences the result, it uses interprocess communication
to retrieve the result from the child process, waiting until the child
finishes if necessary.

    # Example 1: must wait until job finishes before $$result is available
    $result = bg_eval { sleep 3 ; return 42 };
    print "Result is $$result\n";

    # Example 2: $$result is probably available immediately
    $result = bg_eval { sleep 3 ; return 42 };
    &do_something_that_takes_about_5_seconds();
    print "Result is $$result\n";

The code block is always evaluated in scalar context, though it is
acceptable to return a reference:

    $result = bg_eval {
            @files = File::Find::find(\&criteria, @lots_of_dirs);
            return \@files;
        };
    # ... do something else while that job runs ...
    foreach my $matching_file (@$$result) { # note double dereference
        # ... do something with $matching_file
    }

The background job will be spawned with the C<Forks::Super::fork> call,
and the command will block, fail, or defer a background job in accordance
with all of the other rules of this module. Additional options may be
passed to C<bg_eval>  that will be provided to the C<fork> call. For
example:

    $result = bg_eval {
            return get_from_teh_Internet($something, $where);
        } { timeout => 60, priority => 3 };

will return a reference to C<undef> if the operation takes longer
than 60 seconds. Most valid options for the C<fork> call are also valid
options for C<bg_eval>, including timeouts, delays, job dependencies,
names, and callback. The only invalid options for C<bg_eval> are
C<cmd>, C<sub>, C<exec>, and C<child_fh>.

A call to C<bg_eval> will set the variables C<$Forks::Super::LAST_JOB>
and C<$Forks::Super::LAST_JOB_ID>. See L</"MODULE VARIABLES"> below.

=item C<< @result = bg_eval { BLOCK } >>

=item C<< @result = bg_eval { BLOCK } { option => value, ... } >>

Evaluates the specified block of code in a background process and in list
context. The parent process retrieves the result from the child through
interprocess communication the first time that an element of the array
is referenced; the parent will wait for the child to finish if necessary.

The background job will be spawned with the C<Forks::Super::fork>
call, and the command will block, fail, or defer a background job in
accordance with all of the rules of this module. Additional options may
be passed to the C<bg_eval> function that will be provided to the
C<Forks::Super::fork> call. For example:

    @result = bg_eval {
            count_words($a_huge_file)
        } { timeout => 60 };

will return an empty list if the operation takes longer than
60 seconds. Any valid options for the C<fork> call are also valid
options for C<bg_eval>, except for C<exec>, C<cmd>, C<sub>, and
C<child_fh>.

A call to C<bg_eval> will set the variables C<$Forks::Super::LAST_JOB>
and C<$Forks::Super::LAST_JOB_ID>. See L</"MODULE VARIABLES"> below.

=head3 bg_qx

=item C<< $reference = bg_qx $command >>

=item C<< $reference = bg_qx $command, { option => value , ... } >>

Executes the specified shell command in a background process. When the
parent process dereferences the result, it uses interprocess communication
to retrieve the output from the child process, waiting until the child
finishes if necessary. The deferenced value will contain the output
from the command.

Think of this command as a background version of Perl's backticks
or C<qx()> function.

The background job will be spawned with the C<Forks::Super::fork> call,
and the command will block, fail, or defer a background job in accordance
with all of the other rules of this module. Additional options may be
passed to C<bg_eval>  that will be provided to the C<fork> call. For
example, this command

    $result = bg_qx "nslookup joe.schmoe.com", { timeout => 15 };

will run C<nslookup> in a background process for up to 15 seconds.
The expression C<$$result> will then contain all of the output
produced by the process up until the time it was terminated.
Most valid options for the C<fork> call are also valid
options for C<bg_eval>, including timeouts, delays, job dependencies,
names, and callback. The only invalid options for C<bg_eval> are
C<cmd>, C<sub>, C<exec>, and C<child_fh>.

A call to C<bg_qx> will set the variables C<$Forks::Super::LAST_JOB>
and C<$Forks::Super::LAST_JOB_ID>. See L</"MODULE VARIABLES"> below.

=item C<< @result = bg_qx $command >>

=item C<< @result = bg_qx $command, { option => value , ... } >>

Like the scalar context form of the C<bg_qx> command, but
loads output of the specified command into an array,
one element per line (as defined by the current record separator
C<$/>). The command will run in a background process. The first
time that an element of the array is accessed, the parent
will retrieve the output of the command, waiting until the child
finishes if necessary.

Think of this command as a background version of Perl's backticks
or C<qx()> function.

The background job will be spawned with the C<Forks::Super::fork> call,
and the command will block, fail, or defer a background job in accordance
with all of the other rules of this module. Additional options may be
passed to C<bg_eval>  that will be provided to the C<fork> call. For
example, this command

    @result = bg_qx "ssh $remotehost who", { timeout => 15 };

will run in a background process for up to 15 seconds. C<@result>
will then contain all of the output
produced by the process up until the time it was terminated.
Most valid options for the C<fork> call are also valid
options for C<bg_eval>, including timeouts, delays, job dependencies,
names, and callback. The only invalid options for C<bg_eval> are
C<cmd>, C<sub>, C<exec>, and C<child_fh>.

A call to C<bg_qx> will set the variables C<$Forks::Super::LAST_JOB>
and C<$Forks::Super::LAST_JOB_ID>. See L</"MODULE VARIABLES"> below.

=back

=head1 MODULE VARIABLES

Module variables may be initialized on the C<use Forks::Super> line

    # set max simultaneous procs to 5, allow children to call CORE::fork()
    use Forks::Super MAX_PROC => 5, CHILD_FORK_OK => -1;

or they may be set explicitly in the code:

    $Forks::Super::ON_BUSY = 'queue';
    $Forks::Super::FH_DIR = "/home/joe/temp-ipc-files";

Module variables that may be of interest include:

=over 4

=head3 MAX_PROC

=item C<$Forks::Super::MAX_PROC>

The maximum number of simultaneous background processes that can
be spawned by C<Forks::Super>. If a C<fork> call is attempted while
there are already at least this many active background processes,
the behavior of the C<fork> call will be determined by the
value in C<$Forks::Super::ON_BUSY> or by the C<on_busy> option passed
to the C<fork> call.

This value will be ignored during a C<fork> call if the C<force>
option is passed to C<fork> with a non-zero value. The value might also
not be respected if the user supplies a code reference in the
C<can_launch> option and the user-supplied code does not test
whether there are already too many active proceeses.

=head3 ON_BUSY

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
a later time. Also see the C<queue_priority> option to C<fork>
to set the urgency level of a job in case it is deferred.
The return value will be a large and negative
job ID.

This value will be ignored in favor of an C<on_busy> option
supplied to the C<fork> call.

=head3 CHILD_FORK_OK

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

=head3 DEBUG

=item C<$Forks::Super::DEBUG, Forks::Super::DEBUG>

To see the internal workings of the C<Forks::Super> module, set
C<$Forks::Super::DEBUG> to a non-zero value. Information messages
will be written to the C<Forks::Super::Debug::DEBUG_fh> filehandle. By default
C<Forks::Super::Debug::DEBUG_fh> is aliased to C<STDERR>, but it may be reset
by the module user at any time.

Debugging behavior may be overridden for specific jobs
if the C<debug> or C<undebug> option is provided to C<fork>.

=head3 %CHILD_STDxxx

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

=head3 ALL_JOBS

=item C<@Forks::Super::ALL_JOBS>

=item C<%Forks::Super::ALL_JOBS>

List of all C<Forks::Super::Job> objects that were created
from C<fork()> calls, including deferred and failed jobs.
Both process IDs and job IDs for jobs that were deferred at
one time) can be used to look up Job objects in the
C<%Forks::Super::ALL_JOBS> table.

=head3 QUEUE_INTERRUPT

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

=head3 TIMEOUT

=item C<Forks::Super::TIMEOUT>

A possible return value from C<wait> and C<waitpid>
functions when a timeout argument is supplied.
The value indicating a timeout should not collide with any other
possible value from those functions, and should be recognizable
as not an actual process ID.

=head3 LAST_JOB

=item C<$Forks::Super::LAST_JOB_ID>

=item C<$Forks::Super::LAST_JOB>

Calls to the C<bg_eval> and C<bg_qx> functions launch
a background process and set the variables C<$Forks::Super::LAST_JOB_ID>
to the job's process ID and C<$Forks::Super::LAST_JOB> to the job's
L<Forks::Super::Job> object. These functions do not explicitly
return the job id, so these variables provide a convenient way
to query that state of the jobs launched by these functions.

Some C<bash> users will immediately recognize the parallels
between these variables and the bash C<$!> variable, which
captures the process id of the last job to be run in the background.

=head3 WAIT_ACTION_ON_SUSPENDED_JOBS

=item C<$Forks::Super::WAIT_ACTION_ON_SUSPENDED_JOBS>

Governs the action of a call to C<wait>, C<waitpid>, or
C<waitall> in the case when all remaining jobs are in the
C<SUSPENDED> or C<DEFERRED-SUSPENDED> state (see
L<Forks::Super::Job/"state">). Allowable values for this variable
are

=over 4

=item C<wait>

Causes the call to C<wait>/C<waitpid> to block indefinitely 
until those jobs start and one or more of them is completed. 
In this case it is presumed that the queue monitor is running periodically
and conditions that allow those jobs to get started will occur.
This is the default setting for this variable.

=item C<fail>

Causes the C<wait>/C<waitpid> call to return with the special
(negative) value C<Forks::Super::Wait::ONLY_SUSPENDED_JOBS_LEFT>.

=item C<resume>

Causes one of the suspended jobs to be resumed. It is presumed
that this job will complete and allow the C<wait>/C<waitpid>
function to return.


=back

=back

=head1 EXPORTS

This module always exports the C<fork>, C<wait>, C<waitpid>, 
and C<waitall> functions, overloading the Perl system calls
with the same names. Mixing C<Forks::Super> calls with the
similarly-named Perl calls sis strongly discouraged, but you
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

A process id or job id that was specified as a C<depend_on> or C<depend_start>
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

A C<fork> call was made using the incompatible options C<exec> and C<timeout>.

=back

=head1 INCOMPATIBILITIES

This module requires its own C<SIGCHLD> handler,
and is incompatible with any module that tries to
install another C<SIGCHLD> handler. In particular,
if L<you are used to|perlfunc/"fork"> setting

    $SIG{CHLD} = 'IGNORE'

in your code, cut it out.

Some features use the C<alarm> function and custom
C<SIGALRM> handlers in the child processes. Using other
modules that employ this functionality may cause
undefined behavior. Systems and versions that do not
implement the C<alarm> function (like MSWin32 prior to
Perl v5.7) will not be able to use these features.

The first time that a task is deferred, by default this
module will try to install a C<SIGUSR1> handler. See
the description of C<$Forks::Super::QUEUE_INTERRUPT>
under L</"MODULE VARIABLES"> for changing this behavior
if you intended to use a C<SIGUSR1> handler for
something else.

=head1 DEPENDENCIES

The C<bg_eval> function requires either L<YAML> or L<JSON>.
If neither module is available, then using C<bg_eval> will result in
a fatal error.

Otherwise, there are no hard dependencies
on non-core modules. Some features, especially operating-system
specific functions,
depend on some modules (L<Win32::API> and L<Win32::Process>
for Wintel systems, for example), but the module will
compile without those modules. Attempts to use these features
without the required modules will be silently ignored.

=head1 BUGS AND LIMITATIONS

=head2 Leftover temporary files and directories

In programs that use the interprocess communication features, 
the module does not always do a good job of cleaning up after
itself. You may find directories called C<< .fhfork<nnn> >>
that may or not be empty scattered around your filesystem.

=head2 Interrupted system calls

A typical script using this module will have a lot of
behind-the-scenes signal handling as child processes
finish and are reaped. These frequent interruptions can
affect the execution of your program. For example, in
this script:

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

It should be noted that signal handling in Perl is much
improved with version 5.7.3, and the problems caused by
such interruptions are much more tractable than they
used to be.

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

=cut

=head1 SEE ALSO

There are reams of other modules on CPAN for managing background
processes. See Parallel::*, L<Proc::Parallel>, L<Proc::Fork>, 
L<Proc::Launcher>. Also L<Win32::Job>.

Inspiration for C<bg_eval> function from L<Acme::Fork::Lazy>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2010, Marty O'Brien.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

TODO in future releases: See TODO file.
