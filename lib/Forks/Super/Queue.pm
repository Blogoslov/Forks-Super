package Forks::Super::Queue;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Tie::Enum;
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT_OK = qw(queue_job);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our (@QUEUE, $QUEUE_MONITOR_PID, $QUEUE_MONITOR_PPID, $QUEUE_MONITOR_FREQ);
our $DEFAULT_QUEUE_PRIORITY = 0;
our $INHIBIT_QUEUE_MONITOR = 1;
our $NEXT_DEFERRED_ID = -100000;
our $OLD_SIG;
# use var $Forks::Super::QUEUE_INTERRUPT, not lexical package var


sub get_default_priority {
  my $q = $DEFAULT_QUEUE_PRIORITY;
  $DEFAULT_QUEUE_PRIORITY -= 1.0E-6;
  return $q;
}

sub init {
  $QUEUE_MONITOR_FREQ = 30;
  tie $Forks::Super::QUEUE_INTERRUPT, 'Tie::Enum', ('', keys %SIG);
  $Forks::Super::QUEUE_INTERRUPT = 'USR1' if grep {/USR1/} keys %SIG;
  $INHIBIT_QUEUE_MONITOR = $^O eq "MSWin32";
}

sub init_child {
  @QUEUE = ();
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
  
  $OLD_SIG = $SIG{$Forks::Super::QUEUE_INTERRUPT};
  $SIG{$Forks::Super::QUEUE_INTERRUPT} = \&Forks::Super::Queue::check_queue;
  $QUEUE_MONITOR_PPID = $$;
  $QUEUE_MONITOR_PID = CORE::fork();
  if (not defined $QUEUE_MONITOR_PID) {
    warn "Forks::Super: ",
      "queue monitoring sub process could not be launched: $!\n";
    return;
  }
  if ($QUEUE_MONITOR_PID == 0) {
    defined &Forks::Super::init_child 
      ? Forks::Super::init_child() : init_child();
    $SIG{QUIT} = 'DEFAULT';
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
      if (kill 'QUIT', $QUEUE_MONITOR_PID) {
	undef $QUEUE_MONITOR_PID;
	# $SIG{$Forks::Super::QUEUE_INTERRUPT} = $OLD_SIG;
      }
    }
  }
}

END {
  _kill_queue_monitor();
}

#
# add a new job to the queue.
# may run with no arg to populate queue from existing
# deferred jobs
#
sub queue_job {
  my $job = shift;
  if (defined $job) {
    $job->{state} = 'DEFERRED';
    $job->{pid} = $NEXT_DEFERRED_ID--;
    $Forks::Super::ALL_JOBS{$job->{pid}} = $job;
  }

  my @q = grep { $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
  @QUEUE = @q;

  if (@QUEUE > 0 && !$QUEUE_MONITOR_PID && !$INHIBIT_QUEUE_MONITOR) {
    _launch_queue_monitor();
  }
  if (@QUEUE == 0) {
    _kill_queue_monitor();
  }
  return;
}

#
# attempt to launch all jobs that are currently in the
# DEFFERED state.
#
sub run_queue {
  my ($ignore) = @_;
  return if @QUEUE <= 0;

  # XXX - synchronize this function?

  # tasks for run_queue:
  #   assemble all DEFERRED jobs
  #   order by priority
  #   go through the list and attempt to launch each job in order.

  debug('run_queue(): examining deferred jobs') if $DEBUG;
  my $job_was_launched;
  do {
    $job_was_launched = 0;
    my @deferred_jobs = sort { $b->{queue_priority} <=> $a->{queue_priority} }
      grep { defined $_->{state} &&
	       $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
    foreach my $job (@deferred_jobs) {
      if ($job->can_launch) {
	debug("Launching deferred job $job->{pid}")
	  if $job->{debug};
	$job->{state} = "LAUNCHING";
	my $pid = $job->launch();
	if ($pid == 0) {
	  if (defined $job->{sub} or defined $job->{cmd} 
	      or defined $job->{exec}) {
	    croak "Forks::Super::run_queue(): ",
	      "fork on deferred job unexpectedly returned ",
		"a process id of 0!\n";
	  }
	  croak "Forks::Super::run_queue(): ",
	    "deferred job must have a 'sub', 'cmd', or 'exec' option!\n";
	}
	$job_was_launched = 1;
	last;
      } elsif ($job->{debug}) {
	debug("Still must wait to launch job $job->{pid}");
      }
    }
  } while ($job_was_launched);
  queue_job(); # refresh @QUEUE
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
  run_queue();
  return;
}

1;
