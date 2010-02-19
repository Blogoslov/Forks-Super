package Forks::Super::Job::Timeout;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use POSIX;
use Carp;
use strict;
use warnings;

our $MAIN_PID = $Forks::Super::MAIN_PID || $$;
our $DISABLE_TERM = 0;
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
    if ($job->{style} eq "exec") {
      carp "Forks::Super: exec option used, timeout option ignored\n";
      return;
    }
  }
  if (defined $job->{expiration}) {
    if ($job->{expiration} - Forks::Super::Util::Time() < $timeout) {
      $timeout = $job->{expiration} - Forks::Super::Util::Time();
    }
    if ($job->{style} eq "exec") {
      carp "Forks::Super: exec option used, expiration option ignored\n";
      return;
    }
  }
  if ($timeout > 9E8) {
    return;
  }

  # if possible in this OS, establish a new process group for
  # this child. If this process times out, we want to have
  # an easy way to kill off all the grandchildren.
  #
  # see the END{} block that covers child cleanup below
  #
  if (Forks::Super::Config::CONFIG("getpgrp")) {
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
      croak "Forks::Super: quick timeout\n";
    } 
    croak "Forks::Super::Job::config_timeout_child(): quick timeout";
  }

  $SIG{ALRM} = sub {
    warn "Forks::Super: child process timeout\n";
    $TIMEDOUT = 1;
    if (Forks::Super::Config::CONFIG("getpgrp") &&
	($NEW_SETSID || $NEW_PGRP ne $ORIG_PGRP)) {
      $DISABLE_TERM = 1;
      my $nk = kill 'TERM', -getpgrp(0);
      $DISABLE_TERM = 0;
    }
    exit 255;
  };
  if (Forks::Super::Config::CONFIG("alarm")) {
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
  if ($$ != $MAIN_PID) {
    if (Forks::Super::Config::CONFIG("alarm")) {
      alarm 0;
    }
    if ($TIMEDOUT && Forks::Super::Config::CONFIG("getpgrp")) {
      if ($DISABLE_TERM) {
	# our child process received its own SIGTERM that got sent out
	# to its children/process group. We intended the exit status
	# here to be as if it had die'd.
	$? = 255 << 8;
      }

      # try to kill off any grandchildren
      if ($ORIG_PGRP == $NEW_PGRP) {
	carp "Forks::Super::child_exit: original setpgrp call failed, ",
	  "child-of-child process might not be terminated.\n";
      } else {
	setpgrp(0, $MAIN_PID);
	$NEWNEW_PGRP = getpgrp(0);
	if ($NEWNEW_PGRP eq $NEW_PGRP) {
	  carp "Forks::Super::child_exit: final setpgrp call failed, ",
	    "child-of-child processes might not be terminated.\n";
	} else {
	  my $num_killed = kill 'TERM', -$NEW_PGRP;
	  if ($num_killed && $NEW_PGRP) {
	    Forks::Super::debug("Forks::Super::child_exit: sent SIGTERM to ",
				"$num_killed grandchildren");
	  }
	}
      }
    }
  }
}

1;

