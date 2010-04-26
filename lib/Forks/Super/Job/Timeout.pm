#
# Forks::Super::Job::Timeout
# implementation of
#     fork { timeout => ... }
#     fork { expiration => ... }
#

package Forks::Super::Job::Timeout;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use POSIX;
use Carp;
use strict;
use warnings;

our $VERSION = $Forks::Super::Debug::VERSION;
our $MAIN_PID = $$;
our $DISABLE_INT = 0;
our $TIMEDOUT = 0;
our ($ORIG_PGRP, $NEW_PGRP, $NEW_SETSID, $NEWNEW_PGRP);

#
# If desired, set an alarm and alarm signal handler on a child process
# to kill the child.
# Should only run from a child process immediately after the fork.
#
sub config_timeout_child {
  my $job = shift;
  my $timeout = 9E9;
  if (defined $job->{timeout}) {
    $timeout = $job->{timeout};
    if ($job->{style} eq 'exec') {
      carp "Forks::Super: exec option used, timeout option ignored\n";
      return;
    }
  }
  if (defined $job->{expiration}) {
    if ($job->{expiration} - Forks::Super::Util::Time() < $timeout) {
      $timeout = $job->{expiration} - Forks::Super::Util::Time();
    }
    if ($job->{style} eq 'exec') {
      carp "Forks::Super: exec option used, expiration option ignored\n";
      return;
    }
  }
  if ($timeout > 9E8) {
    return;
  }

  # Un*x systems - try to establish a new process group for
  # this child. If this process times out, we want to have
  # an easy way to kill off all the grandchildren.
  #
  # On Windows, if a child (i.e., a psuedo-process) launches
  # a REAL process (with system, exec, Win32::Process::Create, etc.)
  # then the only reliable way I've found to take it out is
  # with the system command TASKKILL.
  #
  # see the END{} block that covers child cleanup below
  #
  if (Forks::Super::Config::CONFIG('getpgrp')) {
    $ORIG_PGRP = getpgrp(0);
    setpgrp(0, $$);
    $NEW_PGRP = $job->{pgid} = getpgrp(0);
    $NEW_SETSID = 0;
    if ($NEW_PGRP ne $ORIG_PGRP) {
      if ($job->{debug}) {
	debug("Forks::Super::Job::config_timeout_child: ",
	     "Child process group changed to $job->{pgid}");
      }
    } else {
      # setpgrp didn't work, try POSIX::setsid
      $NEW_SETSID = POSIX::setsid();
      $job->{pgid} = $NEW_PGRP = getpgrp(0);
      if ($job->{debug}) {
	debug("Forks::Super::Job::config_timeout_child: ",
	       "Child process started new session $NEW_SETSID, ",
	       "process group $NEW_PGRP");
      }
    }
  }

  if ($timeout < 1) {
    if ($Forks::Super::IMPORT{":test"}) {
      die "Forks::Super: quick timeout\n";
    }
    croak "Forks::Super::Job::config_timeout_child(): quick timeout";
  }

  $SIG{ALRM} = sub {
    local *__ANON__ = 'the Forks::Super::Job::Timeout::SIGALRM handler';
    warn "Forks::Super: child process timeout\n";
    $TIMEDOUT = 1;
    if (Forks::Super::Config::CONFIG('getpgrp')) {
      if ($NEW_SETSID || ($ORIG_PGRP ne $NEW_PGRP)) {
	local $SIG{INT} = 'IGNORE';
	$DISABLE_INT = 1;
	CORE::kill -($Forks::Super::Config::signo{'INT'} || 2), getpgrp(0);
	$DISABLE_INT = 0;
      }
    } elsif ($^O eq 'MSWin32') {
      my $proc = Forks::Super::Job::get_win32_proc();
      my $pid = Forks::Super::Job::get_win32_proc_pid();

      if (Forks::Super::Config::CONFIG('Win32::Process') && defined $proc) {

	my $exitCode;
	my $ec = $proc->GetExitCode($exitCode);
	if ($exitCode == &Win32::Process::STILL_ACTIVE
	   || $ec == &Win32::Process::STILL_ACTIVE) {

#	  my $result = $proc->Kill(0x102); # 0x102: "STATUS_TIMEOUT"
#	  my $result = Win32::Process::KillProcess($pid, 0x102);
#	  my $result = kill 9, $pid;

	  # TASKKILL is pretty standard on Windows systems, isn't it?
	  # Maybe not completely standard :-(
	  my $result = system("TASKKILL /F /T /PID $pid > nul");

	  $proc->GetExitCode($exitCode);
	  if ($DEBUG) {
	    debug("Terminating active MSWin32 process result=$result ",
		  "exitCode=$exitCode");
	  }
	}
      } else {
	$DISABLE_INT = 1;
	Forks::Super::kill('INT', $$);
	# CORE::kill 'INT', $$;
	$DISABLE_INT = 0;
      }
    }
    if ($^O eq 'MSWin32' && $DEBUG) {
      debug("Process $$/$Forks::Super::MAIN_PID exiting with code 255");
    }
    exit 255;
  };
  if (Forks::Super::Config::CONFIG('alarm')) {
    alarm $timeout;
    debug("Forks::Super::Job::config_timeout_child(): ",
	  "alarm set for ${timeout}s in child process $$")
      if $job->{debug};
  } else {
    carp "Forks::Super: alarm() not available, ",
      "timeout,expiration options ignored.\n";
  }
  return;
}

END {
  # clean up child
  if ($$ != ($Forks::Super::MAIN_PID || $MAIN_PID)) { # FSJ::Timeout END {}
    if (defined $Forks::Super::Config::CONFIG{'alarm'}
	&& $Forks::Super::Config::CONFIG{'alarm'}) {
      alarm 0;
    }
    if ($TIMEDOUT) {
      if ($DISABLE_INT) {
	# our child process received its own SIGINT that got sent out
	# to its children/process group. We intended the exit status
	# here to be as if it had die'd.

	$? = 255 << 8;
      }
      if (Forks::Super::Config::CONFIG('getpgrp')) {
	# try to kill off any grandchildren
	if ($ORIG_PGRP == $NEW_PGRP) {
	  carp "Forks::Super::child_exit: original setpgrp call failed, ",
	    "child-of-child process might not be terminated.\n";
	} else {
	  setpgrp(0, $ORIG_PGRP);
	  $NEWNEW_PGRP = getpgrp(0);
	  if ($NEWNEW_PGRP eq $NEW_PGRP) {
	    carp "Forks::Super::child_exit: final setpgrp call failed, ",
	      "[$ORIG_PGRP/$NEW_PGRP/$NEWNEW_PGRP] ",
		"child-of-child processes might not be terminated.\n";
	  } else {
	    local $SIG{INT} = 'IGNORE';
	    my $num_killed = CORE::kill 'INT', -$NEW_PGRP; 
	    # kill -PID === kill PGID. Not portable
	    if ($num_killed && $NEW_PGRP && $DEBUG) {
	      debug("Forks::Super::child_exit: sent SIGINT to ",
		    "$num_killed grandchildren");
	    }
	  }
	}
      }
    }
  }
  1; # done
}

sub warm_up {

  # force loading of some modules in the parent process
  # so that fast fail (see t/40-timeout.t, tests #8,17)
  # aren't slowed down when they encounter the croak call.

  eval { croak "preload.\n" };
  return $@;
}

1;
