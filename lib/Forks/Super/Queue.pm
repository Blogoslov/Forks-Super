#
# Forks::Super::Queue - routines to manage "deferred" jobs
#

package Forks::Super::Queue;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Forks::Super::Tie::Enum;
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT_OK = qw(queue_job);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our (@QUEUE, $QUEUE_MONITOR_PID, $QUEUE_MONITOR_PPID);

our $QUEUE_MONITOR_FREQ;
our $DEFAULT_QUEUE_PRIORITY = 0;
our $INHIBIT_QUEUE_MONITOR = 1;
our $NEXT_DEFERRED_ID = -100000;
our $OLD_SIG;
our $VERSION = $Forks::Super::Debug::VERSION;
our $MAIN_PID = $$;
our $QUEUE_MONITOR_LAUNCHED = 0;
our $_LOCK = 0; # ??? can this prevent crash -- no, but it can cause deadlock
our $CHECK_FOR_REAP = 1;
# set flag if the program is shutting down. Use flag in queue_job()
# to suppress warning messages
our $DURING_GLOBAL_DESTRUCTION = 0;

# use var $Forks::Super::QUEUE_INTERRUPT, not lexical package var


sub get_default_priority {
  my $q = $DEFAULT_QUEUE_PRIORITY;
  $DEFAULT_QUEUE_PRIORITY -= 1.0E-6;
  return $q;
}

sub init {
  $QUEUE_MONITOR_FREQ = 30;
  tie $Forks::Super::QUEUE_INTERRUPT, 'Forks::Super::Tie::Enum',
    ('', keys %SIG);
  $Forks::Super::QUEUE_INTERRUPT = 'USR1' if grep {/USR1/} keys %SIG;
  $INHIBIT_QUEUE_MONITOR = $^O eq "MSWin32";
}

sub init_child {
  @QUEUE = ();
  if (defined $SIG{"USR2"}) {
    $SIG{'USR2'} = 'DEFAULT';
  }
  undef $QUEUE_MONITOR_PID;
  if ($Forks::Super::QUEUE_INTERRUPT
      && Forks::Super::Config::CONFIG("SIGUSR1")) {
    $SIG{$Forks::Super::QUEUE_INTERRUPT} = 'DEFAULT';
  }
}

#
# once there are jobs in the queue, we'll need to call
# run_queue() every once in a while to make sure those
# jobs get started when they are eligible. Certain
# events (the CHLD handler being invoked, the
# waitall method) call run_queue but that still doesn't
# guarantee that it will be called frequently enough.
#
# This method sets up a background process (using
# CORE::fork -- it won't be subject to reaping by
# this module's wait/waitpid/waitall methods)
# to periodically send USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals to this
#
sub _launch_queue_monitor {
  return unless Forks::Super::Config::CONFIG("SIGUSR1");
  return if defined $QUEUE_MONITOR_PID;
  return if $QUEUE_MONITOR_LAUNCHED++;

  $OLD_SIG = $SIG{$Forks::Super::QUEUE_INTERRUPT};
  $SIG{$Forks::Super::QUEUE_INTERRUPT} = \&Forks::Super::Queue::check_queue;
  $QUEUE_MONITOR_PPID = $$;
  $QUEUE_MONITOR_PID = CORE::fork();
  if (not defined $QUEUE_MONITOR_PID) {
    warn "Forks::Super: ",
      "queue monitoring sub process could not be launched: $!\n";
    undef $QUEUE_MONITOR_PPID;
    return;
  }
  if ($QUEUE_MONITOR_PID == 0) {
    if ($DEBUG) {
      debug("Launching queue monitor process $$ ",
	    "SIG $Forks::Super::QUEUE_INTERRUPT ",
	    "PPID $QUEUE_MONITOR_PPID ",
	    "FREQ $QUEUE_MONITOR_FREQ ");
    }

    defined &Forks::Super::init_child
      ? Forks::Super::init_child() : init_child();
    $SIG{QUIT} = sub { exit 0 }; # 'DEFAULT';
    for (;;) {
      sleep $QUEUE_MONITOR_FREQ;
      kill $Forks::Super::QUEUE_INTERRUPT, $QUEUE_MONITOR_PPID;
    }
    exit 0;
  }
  return;
}

sub _kill_queue_monitor {
  if (defined $QUEUE_MONITOR_PPID && $$ == $QUEUE_MONITOR_PPID) {
    if (defined $QUEUE_MONITOR_PID && $QUEUE_MONITOR_PID > 0) {
      my $nk = kill 'QUIT', $QUEUE_MONITOR_PID;
      if ($DEBUG) {
	debug("killing queue monitor process: $nk");
      }
      if ($nk) {
	undef $QUEUE_MONITOR_PID;
	undef $QUEUE_MONITOR_PPID;
	if (defined $OLD_SIG) {
	  $SIG{$Forks::Super::QUEUE_INTERRUPT} = $OLD_SIG;
	}
      }
    }
  }
}


END {
  $DURING_GLOBAL_DESTRUCTION = 1;
  _kill_queue_monitor();
}

#
# add a new job to the queue.
# may run with no arg to populate queue from existing
# deferred jobs
#
sub queue_job {
  my $job = shift;
  if ($DURING_GLOBAL_DESTRUCTION) {
    return;
  }
  if (defined $job) {
    $job->{state} = 'DEFERRED';
    $job->{pid} = $NEXT_DEFERRED_ID--;
    $Forks::Super::ALL_JOBS{$job->{pid}} = $job;
    if ($DEBUG) {
      debug("queueing job ", $job->toString());
    }
  }

  my @q = grep { $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
  @QUEUE = @q;
  if (@QUEUE > 0 && !$QUEUE_MONITOR_PID && !$INHIBIT_QUEUE_MONITOR) {
    _launch_queue_monitor();
  }
  return;
}

our $_REAP;

sub _check_for_reap {
  if ($CHECK_FOR_REAP && $_REAP > 0) {
    if ($DEBUG) {
      debug("reap during queue examination -- restart");
    }
    return 1;
  }
}


#
# attempt to launch all jobs that are currently in the
# DEFFERED state.
#
sub run_queue {
  my ($ignore) = @_;
  return if @QUEUE <= 0;
  # XXX - run_queue from child ok if $Forks::Super::CHILD_FORK_OK
  return if $$ != ($Forks::Super::MAIN_PID || $MAIN_PID);
  queue_job();
  return if @QUEUE <= 0;
  if ($_LOCK++ > 0) {
    $_LOCK--;
    return;
  }

  # tasks for run_queue:
  #   assemble all DEFERRED jobs
  #   order by priority
  #   go through the list and attempt to launch each job in order.

  debug('run_queue(): examining deferred jobs') if $DEBUG;
  my $job_was_launched;
  do {
    $job_was_launched = 0;
    $_REAP = 0;
    my @deferred_jobs = sort { $b->{queue_priority} <=> $a->{queue_priority} }
      grep { defined $_->{state} &&
	       $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
    foreach my $job (@deferred_jobs) {
      if ($job->can_launch) {
	if ($job->{debug}) {
	  debug("Launching deferred job $job->{pid}")
	}
	$job->{state} = "LAUNCHING";

	# if this loop gets interrupted to handle a child,
	# we might be launching jobs in the wrong order.
	# If we detect that an interruption has happened,
	# abort and restart the loop.
	# To disable this check, set $Forks::Super::Queue::CHECK_FOR_REAP := 0

	if (_check_for_reap()) {
	  $job->{state} = "DEFERRED";
	  $job_was_launched = 1;
	  last;
	}
	my $pid = $job->launch();
	if ($pid == 0) {
	  if (defined $job->{sub} or defined $job->{cmd}
	      or defined $job->{exec}) {
	    $_LOCK--;
	    croak "Forks::Super::run_queue(): ",
	      "fork on deferred job unexpectedly returned ",
		"a process id of 0!\n";
	  }
	  $_LOCK--;
	  croak "Forks::Super::run_queue(): ",
	    "deferred job must have a 'sub', 'cmd', or 'exec' option!\n";
	}
	$job_was_launched = 1;
	last;
      } elsif ($job->{debug}) {
	debug("Still must wait to launch job ", $job->toShortString());
      }
    }
  } while ($job_was_launched);
  $_LOCK--;
  return;
}

#
# SIGUSR1 handler. A background process will send periodic USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals back to this process. On
# receipt of these signals, this process should examine the queue.
# This will keep us from ignoring the queue for too long.
#
# Note this automatic housecleaning is not available on some OS's
# like Windows. Those users may need to call  Forks::Super::Queue::check_queue
# or  Forks::Super::run_queue  manually from time to time.
#
sub check_queue {
  run_queue() if !$_LOCK;
  return;
}

1;
