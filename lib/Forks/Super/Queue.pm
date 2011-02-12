#
# Forks::Super::Queue - routines to manage "deferred" jobs
#

package Forks::Super::Queue;

use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Forks::Super::Tie::Enum;
use Forks::Super::Util qw(IS_WIN32);
use Forks::Super::Sighandler;
use Carp;

use Exporter;
our @ISA = qw(Exporter);
#use base 'Exporter';

use strict;
use warnings;

our @EXPORT_OK = qw(queue_job);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our $VERSION = $Forks::Super::Util::VERSION;

our (@QUEUE, $QUEUE_MONITOR_PID, $QUEUE_MONITOR_PPID, $QUEUE_MONITOR_FREQ);
our $QUEUE_DEBUG = $ENV{FORKS_SUPER_QUEUE_DEBUG} || 0;
our $QUEUE_MONITOR_LIFESPAN = 14400;
our $DEFAULT_QUEUE_PRIORITY = 0;
our $INHIBIT_QUEUE_MONITOR = 1;
our $NEXT_DEFERRED_ID = -100000;
our $OLD_QINTERRUPT_SIG;
our ($MAIN_PID,$_LOCK) = ($$,0);

# if a child process finishes while the  run_queue()  function is running,
# we will usually have to restart that function in order to make sure
# that jobs are dispatched quickly and in the correct order. The SIGCHLD
# handler sets the flag  $_REAP , and if we check that flag  run_queue()
# will do its job properly.
our ($CHECK_FOR_REAP, $_REAP) = (1,0);

# use var $Forks::Super::QUEUE_INTERRUPT, not lexical package var

sub get_default_priority {
  my $q = $DEFAULT_QUEUE_PRIORITY;
  $DEFAULT_QUEUE_PRIORITY -= 1.0E-6;
  return $q;
}

sub init {
  tie $QUEUE_MONITOR_FREQ, 
    'Forks::Super::Queue::QueueMonitorFreq', 30;

  tie $INHIBIT_QUEUE_MONITOR, 
    'Forks::Super::Queue::InhibitQueueMonitor', &IS_WIN32;
    # !Forks::Super::Util::_has_POSIX_signal_framework();

  tie $Forks::Super::QUEUE_INTERRUPT, 
    'Forks::Super::Queue::QueueInterrupt', ('', keys %SIG);
  if (grep {/USR1/} keys %SIG) {
    $Forks::Super::QUEUE_INTERRUPT = 'USR1';
  }
}

sub init_child {
  @QUEUE = ();
  undef $QUEUE_MONITOR_PID;
  if ($Forks::Super::QUEUE_INTERRUPT
      && $Forks::Super::SysInfo::CONFIG{SIGUSR1}) {
    $SIG{$Forks::Super::QUEUE_INTERRUPT} = 'DEFAULT';
  }
}

#
# once there are jobs in the queue, we'll need to call
# check_queue() every once in a while to make sure those
# jobs get started when they are eligible. Certain
# events (the CHLD handler being invoked, the
# waitall method) call check_queue but that still doesn't
# guarantee that it will be called frequently enough.
#
# This method sets up a background process (using
# CORE::fork -- it won't be subject to reaping by
# this module's wait/waitpid/waitall methods)
# to periodically send USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals to this
#
sub _launch_queue_monitor {
  if (!$Forks::Super::SysInfo::CONFIG{'SIGUSR1'}) {
    debug("_lqm returning: no SIGUSR1") if $QUEUE_DEBUG;
    return;
  }
  if (defined $QUEUE_MONITOR_PID) {
    debug("_lqm returning: \$QUEUE_MONITOR_PID defined") if $QUEUE_DEBUG;
    return;
  }

  if ($Forks::Super::SysInfo::CONFIG{'setitimer'}) {
    _launch_queue_monitor_setitimer();
  } else {
    _launch_queue_monitor_fork();
  }
}

sub _check_queue {
  # XXX - check_queue call triggered by a SIGALRM. 
  #       do we want to log it or do any other special handling?
  check_queue();
}

sub _launch_queue_monitor_setitimer {

  $QUEUE_MONITOR_PPID = $$;
  $QUEUE_MONITOR_PID = 'setitimer';
  # $Forks::Super::Sighandler::DEBUG = 1;
  register_signal_handler("ALRM", 2, \&_check_queue);
						   
  Time::HiRes::setitimer(
	&Time::HiRes::ITIMER_REAL, $QUEUE_MONITOR_FREQ, $QUEUE_MONITOR_FREQ);
}

sub _launch_queue_monitor_fork {

  if (!(defined $Forks::Super::QUEUE_INTERRUPT
	&& $Forks::Super::QUEUE_INTERRUPT)) {
    debug("_lqm returning: \$Forks::Super::QUEUE_INTERRUPT not set")
      if $QUEUE_DEBUG;
    return;
  }

  $OLD_QINTERRUPT_SIG = $SIG{$Forks::Super::QUEUE_INTERRUPT};
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
    $0 = "QMon:$QUEUE_MONITOR_PPID";
    if ($DEBUG || $QUEUE_DEBUG) {
      debug("Launching queue monitor process $$ ",
	    "SIG $Forks::Super::QUEUE_INTERRUPT ",
	    "PPID $QUEUE_MONITOR_PPID ",
	    "FREQ $QUEUE_MONITOR_FREQ ");
    }

    if (defined &Forks::Super::init_child) {
      Forks::Super::init_child();
    } else {
      init_child();
    }
    close STDIN;
    close STDOUT;
    close STDERR unless $DEBUG || $QUEUE_DEBUG;
    $SIG{'TERM'} = 'DEFAULT';

    # three (normal) ways the queue monitor can die:
    #  1. (preferred) killed by the calling process (_kill_queue_monitor)
    #  2. fails to signal calling process 10 straight times
    #  3. exit after $QUEUE_MONITOR_LIFESPAN seconds

    my $expire = time + $QUEUE_MONITOR_LIFESPAN;
    my $consecutive_failures = 0;
    while (time < $expire && $consecutive_failures < 10) {
      sleep $QUEUE_MONITOR_FREQ;

      if ($DEBUG || $QUEUE_DEBUG) {
	debug("queue monitor $$ passing signal to $QUEUE_MONITOR_PPID");
      }
      if (CORE::kill $Forks::Super::QUEUE_INTERRUPT, $QUEUE_MONITOR_PPID) {
	$consecutive_failures = 0;
      } else {
	$consecutive_failures++;
      }
      last if time > $expire;
    }
    exit 0;
  }
  return;
}

sub _kill_queue_monitor {
  if (defined($QUEUE_MONITOR_PPID) && $$ == $QUEUE_MONITOR_PPID) {
    if (defined $QUEUE_MONITOR_PID) {
      if ($DEBUG || $QUEUE_DEBUG) {
	debug("killing queue monitor $QUEUE_MONITOR_PID");
      }
	
      if ($QUEUE_MONITOR_PID eq 'setitimer') {

	register_signal_handler("ALRM", 1, undef);
	register_signal_handler("ALRM", 2, undef);
	Time::HiRes::setitimer(&Time::HiRes::ITIMER_REAL, 0);
	undef $QUEUE_MONITOR_PID;
	undef $QUEUE_MONITOR_PPID;

      } elsif ($QUEUE_MONITOR_PID > 0) {

	# on linux x86_64-linux, is this the source of the t/42d failures?
	CORE::kill 'TERM', $QUEUE_MONITOR_PID;

	my $z = CORE::waitpid $QUEUE_MONITOR_PID, 0;
	if ($DEBUG || $QUEUE_DEBUG) {
	  debug("kill queue monitor result: $z");
	}

	undef $QUEUE_MONITOR_PID;
	undef $QUEUE_MONITOR_PPID;
	if (defined $OLD_QINTERRUPT_SIG) {
	  $SIG{$Forks::Super::QUEUE_INTERRUPT} = $OLD_QINTERRUPT_SIG;
	}
      }
    }
  }
}


sub _cleanup {
  _kill_queue_monitor();
}

#
# add a new job to the queue.
# may run with no arg to populate queue from existing
# deferred jobs
#
sub queue_job {
  my $job = shift;
  if ($Forks::Super::Job::INSIDE_END_QUEUE) {
    return;
  }
  if (defined $job) {
    $job->{state} = 'DEFERRED';
    $job->{queued} ||= Time::HiRes::time();
    $job->{pid} = $NEXT_DEFERRED_ID--;
    $Forks::Super::ALL_JOBS{$job->{pid}} = $job;
    if ($DEBUG || $QUEUE_DEBUG) {
      debug("queueing job ", $job->toString());
    }
  }

  my @q = grep { $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
  @QUEUE = @q;
  if (@QUEUE > 0 && !$QUEUE_MONITOR_PID && !$INHIBIT_QUEUE_MONITOR) {
    _launch_queue_monitor();
  } elsif (@QUEUE == 0 && defined $QUEUE_MONITOR_PID) {
    _kill_queue_monitor();
  }
  return;
}

sub _check_for_reap {
  if ($CHECK_FOR_REAP && $_REAP > 0) {
    if ($DEBUG || $QUEUE_DEBUG) {
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
  if (@QUEUE <= 0) {
    return;
  }
  if ($Forks::Super::Job::INSIDE_END_QUEUE > 0) {
    return;
  }
  # XXX - run_queue from child ok if $Forks::Super::CHILD_FORK_OK
  {
    no warnings 'once';
    return if $$ != ($Forks::Super::MAIN_PID || $MAIN_PID);
  }
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

  debug('run_queue(): examining deferred jobs') if $DEBUG || $QUEUE_DEBUG;
  my $job_was_launched;
  do {
    $job_was_launched = 0;
    $_REAP = 0;
    my @deferred_jobs = grep {
      defined $_->{state} && $_->{state} eq 'DEFERRED'
    } @Forks::Super::ALL_JOBS;
    @deferred_jobs = sort {
      ($b->{queue_priority} || 0) 
	      <=> 
      ($a->{queue_priority} || 0)
    } @deferred_jobs;

    foreach my $job (@deferred_jobs) {
      if ($job->can_launch) {
	if ($job->{debug}) {
	  debug("Launching deferred job $job->{pid}")
	}
	$job->{state} = 'LAUNCHING';

	# if this loop gets interrupted to handle a child,
	# we might be launching jobs in the wrong order.
	# If we detect that an interruption has happened,
	# abort and restart the loop.
	#
	# To disable this check, set 
	# $Forks::Super::Queue::CHECK_FOR_REAP = 0

	if (_check_for_reap()) {
	  $job->{state} = 'DEFERRED';
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

sub suspend_resume_jobs {
  my @jobs = grep {
    defined $_->{suspend} &&
      ($_->{state} eq 'ACTIVE' || $_->{state} eq 'SUSPENDED')
    } @Forks::Super::ALL_JOBS;
  return if @jobs <= 0;

  if ($_LOCK++ > 0) {
    $_LOCK--;
    return;
  }

  debug('suspend_resume_jobs(): examining jobs') if $DEBUG || $QUEUE_DEBUG;

  foreach my $job (@jobs) {
    no strict 'refs';
    my $action = $job->{suspend}->();
    if ($action > 0) {
      if ($job->{state} =~ /SUSPEND/) {
	debug("Forks::Super::Queue: suspend callback value $action for ",
	      "job ", $job->{pid}, " ... resuming") if $job->{debug};
	$job->resume;
      }
    } elsif ($action < 0) {
      if ($job->{state} eq 'ACTIVE') {
	debug("Forks::Super::Queue: suspend callback value $action for ",
	      "job ", $job->{pid}, " ... suspending") if $job->{debug};
	$job->suspend;
      }
    }
  }

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
  suspend_resume_jobs() if !$_LOCK;
  return;
}

#############################################################################

# when $Forks::Super::Queue::QUEUE_MONITOR_FREQ is updated,
# we should restart the queue monitor.

sub Forks::Super::Queue::QueueMonitorFreq::TIESCALAR {
  my ($class,$value) = @_;
  $value = int $value;
  if ($value == 0) {
    $value = 1;
  } elsif ($value < 0) {
    $value = 30;
  }
  debug("new F::S::Q::QueueMonitorFreq obj") if $QUEUE_DEBUG;
  return bless \$value, $class;
}

sub Forks::Super::Queue::QueueMonitorFreq::FETCH {
  my $self = shift;
  debug("F::S::Q::QueueMonitorFreq::FETCH: $$self") if $QUEUE_DEBUG;
  return $$self;
}

sub Forks::Super::Queue::QueueMonitorFreq::STORE {
  my ($self,$new_value) = @_;
  $new_value = int($new_value) || 1;
  $new_value = 30 if $new_value < 0;
  if ($new_value == $$self) {
    debug("F::S::Q::QueueMonitorFreq::STORE noop $$self") if $QUEUE_DEBUG;
    return $$self;
  }
  if ($QUEUE_DEBUG) {
    debug("F::S::Q::QueueMonitorFreq::STORE $$self <== $new_value");
  }
  $$self = $new_value;
  _kill_queue_monitor();
  check_queue();
  _launch_queue_monitor() if @QUEUE > 0;
}

#############################################################################

# When $Forks::Super::Queue::INHIBIT_QUEUE_MONITOR is changed to non-zero,
# always call _kill_queue_monitor.

sub Forks::Super::Queue::InhibitQueueMonitor::TIESCALAR {
  my ($class,$value) = @_;
  $value = 0+!!$value;
  return bless \$value, $class;
}

sub Forks::Super::Queue::InhibitQueueMonitor::FETCH {
  my $self = shift;
  return $$self;
}

sub Forks::Super::Queue::InhibitQueueMonitor::STORE {
  my ($self, $new_value) = @_;
  $new_value = 0+!!$new_value;
  if ($$self != $new_value) {
    if ($new_value) {
      _kill_queue_monitor();
    } else {
      queue_job();
    }
  }
  $$self = $new_value;
  return $$self;
}

#############################################################################

# Restart queue monitor if value for $QUEUE_INTERRUPT is changed.

{
  no warnings 'once';

  *Forks::Super::Queue::QueueInterrupt::TIESCALAR
    = \&Forks::Super::Tie::Enum::TIESCALAR;

  *Forks::Super::Queue::QueueInterrupt::FETCH
    = \&Forks::Super::Tie::Enum::FETCH;
}

sub Forks::Super::Queue::QueueInterrupt::STORE {
  my ($self, $new_value) = @_;
  if (uc $new_value eq uc Forks::Super::Tie::Enum::_get_value($self)) {
    return; # no change
  }
  if (!Forks::Super::Tie::Enum::_has_attr($self,$new_value)) {
    return; # invalid assignment
  }
  _kill_queue_monitor();
  $Forks::Super::Tie::Enum::VALUE{$self} = $new_value;
  _launch_queue_monitor() if @QUEUE > 0;
  return;
}

#############################################################################

1;
