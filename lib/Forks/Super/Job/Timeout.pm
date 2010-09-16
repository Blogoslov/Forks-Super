#
# Forks::Super::Job::Timeout
# implementation of
#     fork { timeout => ... }
#     fork { expiration => ... }
#

package Forks::Super::Job::Timeout;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(IS_WIN32);
use POSIX;
use Carp;
use strict;
use warnings;

our $VERSION = $Forks::Super::Util::VERSION;

our $MAIN_PID = $$;
our $DISABLE_INT = 0;
our $TIMEDOUT = 0;
our ($ORIG_PGRP, $NEW_PGRP, $NEW_SETSID, $NEWNEW_PGRP);

# Signal to help terminate grandchildren on a timeout, for systems that
# let you set process group ID. After a lot of replications I find that
#   - SIGQUIT is not appropriate on Cygwin 5.10 (_cygtls exception msgs)
#   - SIGINT,QUIT not appropriate on Cygwin 5.6.1 (t/40g#3-6 fail)
#   - linux 5.6.2 intermittent problems with any signals
our $TIMEOUT_SIG = $ENV{FORKS_SUPER_TIMEOUT_SIG} || 'HUP';

sub Forks::Super::Job::_config_timeout_parent {
  my $job = shift;
  return;
}

#
# If desired, set an alarm and alarm signal handler on a child process
# to kill the child.
# Should only run from a child process immediately after the fork.
#
sub Forks::Super::Job::_config_timeout_child {
  my $job = shift;
  my $timeout = 9E9;

  if (exists $SIG{$TIMEOUT_SIG}) {
    $SIG{$TIMEOUT_SIG} = 'DEFAULT';
  }

  if (defined $job->{timeout}) {
    $timeout = _time_from_natural_language($job->{timeout}, 1);
    if ($job->{style} eq 'exec') {
      carp "Forks::Super: exec option used, timeout option ignored\n";
      return;
    }
  }
  if (defined $job->{expiration}) {
    $job->{expiration} = _time_from_natural_language($job->{expiration}, 0);
    if ($job->{expiration} - Time::HiRes::gettimeofday() < $timeout) {
      $timeout = $job->{expiration} - Time::HiRes::gettimeofday();
    }
    if ($job->{style} eq 'exec') {
      carp "Forks::Super: exec option used, expiration option ignored\n";
      return;
    }
  }
  if ($timeout > 9E8) {
    return;
  }
  $job->{_timeout} = $timeout;
  $job->{_expiration} = $timeout + Time::HiRes::gettimeofday();

  if (!Forks::Super::Config::CONFIG('alarm')) {
    croak "Forks::Super: alarm() not available on this system. ",
      "timeout,expiration options not allowed.\n";
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
	debug("Forks::Super::Job::_config_timeout_child: ",
	     "Child process group changed to $job->{pgid}");
      }
    } else {
      # setpgrp didn't work, try POSIX::setsid
      $NEW_SETSID = POSIX::setsid();
      $job->{pgid} = $NEW_PGRP = getpgrp(0);
      if ($job->{debug}) {
	debug("Forks::Super::Job::_config_timeout_child: ",
	       "Child process started new session $NEW_SETSID, ",
	       "process group $NEW_PGRP");
      }
    }
  }

  if ($timeout < 1) {
    if (Forks::Super::_is_test()) {
      die "Forks::Super: quick timeout\n";
    }
    croak "Forks::Super::Job::_config_timeout_child(): quick timeout";
  }

  $SIG{ALRM} = \&_child_sigalrm_handler;

  alarm $timeout;
  debug("Forks::Super::Job::_config_timeout_child(): ",
	"alarm set for ${timeout}s in child process $$")
    if $job->{debug};
  return;
}

# to be run in a child if that child times out
sub _child_sigalrm_handler {
  warn "Forks::Super: child process timeout\n";
  $TIMEDOUT = 1;

  # we wish to kill not only this child process,
  # but any other active processes that it has spawned.
  # There are several ways to do this.

  if (Forks::Super::Config::CONFIG('getpgrp')) {
    if ($NEW_SETSID || ($ORIG_PGRP ne $NEW_PGRP)) {
      local $SIG{$TIMEOUT_SIG} = 'IGNORE';
      $DISABLE_INT = 1;
      my $SIG = $Forks::Super::Config::signo{$TIMEOUT_SIG} || 15;
      CORE::kill -$SIG, getpgrp(0);
      $DISABLE_INT = 0;
    }
  } elsif (&IS_WIN32) {
    my $proc = Forks::Super::Job::get_win32_proc();
    my $pid = Forks::Super::Job::get_win32_proc_pid();
    if (defined $proc) {
      if ($proc eq '__open3__') {
	# Win32::Process nice to have but not required.
	# TASKKILL is pretty standard on Windows systems, isn't it?
	# Maybe not completely standard :-(
	my $result = system("TASKKILL /F /T /PID $pid > nul");
      } elsif ($proc eq '__system__') {
	$proc = undef;
	if (defined $Forks::Super::Job::self
	    && $Forks::Super::Job::self->{debug}) {
	  
	  debug("Job ", $Forks::Super::Job::self->toShortString(),
		" has timed out. The grandchildren from this process",
		" are NOT being terminated.");
	}
      } elsif (Forks::Super::Config::CONFIG('Win32::Process')) {
	my ($ec,$exitCode);
	$ec = $proc->GetExitCode($exitCode);
	if ($exitCode == &Win32::Process::STILL_ACTIVE
	    || $ec == &Win32::Process::STILL_ACTIVE) {

	  my $result = system("TASKKILL /F /T /PID $pid > nul");

	  $proc->GetExitCode($exitCode);
	  if ($DEBUG) {
	    debug("Terminating active MSWin32 process result=$result ",
		  "exitCode=$exitCode");
	  }
	}
      }
    } else {
      $DISABLE_INT = 1;
      Forks::Super::kill($TIMEOUT_SIG, $$);
      $DISABLE_INT = 0;
    }
  }
  if (&IS_WIN32 && $DEBUG) {
    debug("Process $$/$Forks::Super::MAIN_PID exiting with code 255");
  }
  exit 255;
}

sub _cleanup_child {
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
  1; # done
}

sub warm_up {

  # force loading of some modules in the parent process
  # so that fast fail (see t/40-timeout.t, tests #8,17)
  # aren't slowed down when they encounter the croak call.

  eval { croak "preload.\n" };
  return $@;
}

sub _time_from_natural_language {
  my ($time,$isInterval) = @_;
  if ($time !~ /[A-Za-z]/) {
    return $time;
  }

  if (Forks::Super::Config::CONFIG("DateTime::Format::Natural")) {
    my $now = DateTime->now;
    my $dt_nl_parser = DateTime::Format::Natural->new(datetime => $now,
						   lang => 'en',
						   prefer_future => 1);
    if ($isInterval) {
      my ($dt) = $dt_nl_parser->parse_datetime_duration($time);
      return $dt->epoch - $now->epoch;
    } else {
      my $dt = $dt_nl_parser->parse_datetime($time);
      return $dt->epoch;
    }
  } else{
    carp "Forks::Super::Job::Timeout: ",
	"time spec $time may contain natural language. ",
	"Install the  DateTime::Format::Natural  module ",
	"to use this feature.\n";
    return $time;
  }
}

1;
