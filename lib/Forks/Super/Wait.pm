#
# Forks::Super::Wait - implementation of Forks::Super:: wait, waitpid,
#        and waitall methods
#


package Forks::Super::Wait;
use Forks::Super::Job;
use Forks::Super::Util qw(is_number isValidPid pause Time);
use Forks::Super::Debug qw(:all);
use Forks::Super::Config;
use Forks::Super::Queue;
use POSIX ':sys_wait_h';
use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our @EXPORT_OK = qw(wait waitpid waitall TIMEOUT WREAP_BG_OK);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our $VERSION = $Forks::Super::Util::VERSION;

our ($productive_pause_code, $productive_waitpid_code);
our $REAP_NOTHING_MSGS = 0;

our $WAIT_ACTION_ON_SUSPENDED_JOBS = 'wait'; # wait | fail | resume

sub set_productive_pause_code (&) {
  $productive_pause_code = shift;
}
sub set_productive_waitpid_code (&) {
  $productive_waitpid_code = shift;
}

use constant TIMEOUT => -1.5;
use constant ONLY_SUSPENDED_JOBS_LEFT => -1.75;
use constant WREAP_BG_OK => WNOHANG() << 1;

sub wait {
  my $timeout = shift || 0;
  $timeout = 1E-6 if $timeout < 0;
  debug("invoked Forks::Super::wait") if $DEBUG;
  return Forks::Super::Wait::waitpid(-1,0,$timeout);
}

sub waitpid {
  my ($target,$flags,$timeout,@dummy) = @_;
  $productive_waitpid_code->() if $productive_waitpid_code;
  $timeout = 0 if !defined $timeout;
  $timeout = 1E-6 if $timeout < 0;

  if (@dummy > 0) {
    carp "Forks::Super::waitpid: Too many arguments\n";
  }
  if (not defined $flags) {
    carp "Forks::Super::waitpid: Not enough arguments\n";
    $flags = 0;
  }

  # waitpid:
  #   -1:    wait on any process
  #   t>0:   wait on process #t
  #    0:    wait on any process in current process group
  #   -t:    wait on any process in process group #t

  # return -1 if there are no eligible procs to wait for
  my $no_hang = ($flags & WNOHANG) != 0;
  my $reap_bg_ok = $flags == WREAP_BG_OK;
  if (is_number($target) && $target == -1) {
    return _waitpid_any($no_hang, $reap_bg_ok, $timeout);
  } elsif (defined $ALL_JOBS{$target}) {
    return _waitpid_target($no_hang, $reap_bg_ok, $target, $timeout);
  } elsif (0 < (my @wantarray = Forks::Super::Job::getByName($target))) {
    return _waitpid_name($no_hang, $reap_bg_ok, $target, $timeout);
  } elsif (!is_number($target)) {
    return -1;
  } elsif ($target > 0) {
    # invalid pid
    return -1;
  } elsif (Forks::Super::Config::CONFIG('getpgrp')) {
    if ($target == 0) {
      $target = getpgrp(0);
    } else {
      $target = -$target;
    }
    return _waitpid_pgrp($no_hang, $reap_bg_ok, $target, $timeout);
  } else {
    return -1;
  }
}

sub waitall {
  my $timeout = shift || 864000;       # XXX - 10 days arbitrary limit is not the Perl way.
  $timeout = 1E-6 if $timeout < 0;
  my $waited_for = 0;
  my $expire = Time() + $timeout ;
  debug("Forks::Super::waitall(): waiting on all procs") if $DEBUG;
  my $pid;
  do {
    # $productive_waitpid_code->() if $productive_waitpid_code;
    $pid = Forks::Super::Wait::wait($expire - Time());
    if ($DEBUG) {
      debug("Forks::Super::waitall: caught pid $pid");
    }
  } while isValidPid($pid) && ++$waited_for && Time() < $expire;
  # $waited_for = -1 * ($waited_for + 0.5) if Time() < $expire;
  return $waited_for;
}

#
# The handle_CHLD() subroutine takes care of reaping
# processes from the operating system. This method's
# part of the relay is taking the reaped process
# and updating the job's state.
#
# Optionally takes a process group ID to reap processes
# from that specific group.
#
# return the process id of the job that was reaped, or
# -1 if no eligible jobs were reaped. In wantarray mode,
# return the number of eligible processes (state == ACTIVE
# or  state == COMPLETE  or  STATE == SUSPENDED) that were
# not reaped.
#
sub _reap {
  my ($reap_bg_ok, $optional_pgid) = @_; # to reap procs from specific group
  $productive_waitpid_code->() if $productive_waitpid_code;
  _handle_bastards();

  my @j = @ALL_JOBS;
  if (defined $optional_pgid) {
    @j = grep { $_->{pgid} == $optional_pgid } @ALL_JOBS;
  }

  # see if any jobs are complete (signaled the SIGCHLD handler)
  # but have not been reaped.
  my @waiting = grep { $_->{state} eq 'COMPLETE' } @j;
  if (!$reap_bg_ok) {
    @waiting = grep { $_->{_is_bg} == 0 } @waiting;
  }
  debug('Forks::Super::_reap(): found ', scalar @waiting,
    ' complete & unreaped processes') if $DEBUG;

  if (@waiting > 0) {
    @waiting = sort { $a->{end} <=> $b->{end} } @waiting;
    my $job = shift @waiting;
    my $real_pid = $job->{real_pid};
    my $pid = $job->{pid};

    if ($job->{debug}) {
      debug("Forks::Super::_reap(): reaping $pid/$real_pid.");
    }
    return $real_pid if not wantarray;

    my ($nactive1, $nalive, $nactive2)
      = Forks::Super::Job::count_processes($reap_bg_ok, $optional_pgid);
    debug("Forks::Super::_reap():  $nalive remain.") if $DEBUG;
    $job->mark_reaped;
    return ($real_pid, $nactive1, $nalive, $nactive2);
  }


  # the failure to reap active jobs may occur because the jobs are still
  # running, or it may occur because the relevant signals arrived at a
  # time when the signal handler was overwhelmed
  my ($nactive1, $nalive, $nactive2)
      = Forks::Super::Job::count_processes($reap_bg_ok, $optional_pgid);

  if ($nactive1 > 0) {
    ++$REAP_NOTHING_MSGS;
    if ($REAP_NOTHING_MSGS % 10 == 0) {
      if (defined $SIG{CHLD} && ref $SIG{CHLD} eq 'CODE') {
	#$SIG{CHLD}->(-1);
      }
    }
  }

  return -1 if not wantarray;
  if ($DEBUG) {
    debug('Forks::Super::_reap(): nothing to reap now. ',
	  "$nactive1 remain.");
  }
  return (-1, $nactive1, $nalive, $nactive2);
}


# wait on any process
sub _waitpid_any {
  my ($no_hang,$reap_bg_ok,$timeout) = @_;
  my $expire = Time() + ($timeout || 864000);
  my ($pid, $nactive2, $nalive, $nactive) = _reap($reap_bg_ok);
  unless ($no_hang) {
    while (!isValidPid($pid) && $nalive > 0) {
      if (Time() >= $expire) {
	return TIMEOUT;
      }
      if ($nactive == 0) {

	if ($WAIT_ACTION_ON_SUSPENDED_JOBS eq 'fail') {
	  return ONLY_SUSPENDED_JOBS_LEFT;
	} elsif ($WAIT_ACTION_ON_SUSPENDED_JOBS eq 'resume') {
	  _active_one_suspended_job($reap_bg_ok);
	}
      }
      pause();
      ($pid, $nactive2, $nalive, $nactive) = _reap($reap_bg_ok);
    }
  }
  if (defined $ALL_JOBS{$pid}) {
    pause() while not defined $ALL_JOBS{$pid}->{status};
    $? = $ALL_JOBS{$pid}->{status};
  }
  return $pid;
}

sub _active_one_suspended_job {
  my @suspended = grep { $_->{state} eq 'SUSPENDED' } @Forks::Super::ALL_JOBS;
  if (@suspended == 0) {
    @suspended = grep { $_->{state} =~ /SUSPENDED/ } @Forks::Super::ALL_JOBS;
  }
  @suspended = sort { 
    $a->{queue_priority} <=> $b->{queue_priority} } @suspended;
  if (@suspended == 0) {
    warn "Forks::Super::_activate_one_suspended_job(): ",
      " can't find an appropriate suspended job to resume\n";
    return;
  }

  my $j1 = $suspended[0];
  $j1->{queue_priority} -= 1E-4;
  $j1->resume;
  return;
}

# wait on a specific process
sub _waitpid_target {
  my ($no_hang, $reap_bg_ok, $target, $timeout) = @_;
  my $expire = Time() + ($timeout || 864000);
  my $job = $ALL_JOBS{$target};
  if (not defined $job) {
    return -1;
  }
  if ($job->{state} eq 'COMPLETE') {
    $job->mark_reaped;
    return $job->{real_pid};
  } elsif ($no_hang  or
	   $job->{state} eq 'REAPED') {
    return -1;
  } else {
    # block until job is complete.
    while ($job->{state} ne 'COMPLETE' and $job->{state} ne 'REAPED') {
      if (Time() >= $expire) {
	return TIMEOUT;
      }
      pause();
      Forks::Super::Queue::run_queue() if $job->{state} eq 'DEFERRED';
    }
    $job->mark_reaped;
    return $job->{real_pid};
  }
}

sub _waitpid_name {
  my ($no_hang, $reap_bg_ok, $target, $timeout) = @_;
  my $expire = Time() + ($timeout || 864000);
  my @jobs = Forks::Super::Job::getByName($target);
  if (@jobs == 0) {
    return -1;
  }
  my @jobs_to_wait_for = ();
  foreach my $job (@jobs) {
    if ($job->{state} eq 'COMPLETE') {
      $job->mark_reaped;
      return $job->{real_pid};
    } elsif ($job->{state} ne 'REAPED' && $job->{state} ne 'DEFERRED') {
      push @jobs_to_wait_for, $job;
    }
  }
  if ($no_hang || @jobs_to_wait_for == 0) {
    return -1;
  }

  # otherwise block until a job is complete
  @jobs = grep {
    $_->{state} eq 'COMPLETE' || $_->{state} eq 'REAPED'
  } @jobs_to_wait_for;
  while (@jobs == 0) {
    if (Time() >= $expire) {
      return TIMEOUT;
    }
    pause();
    Forks::Super::Queue::run_queue()
	if grep {$_->{state} eq 'DEFERRED'} @jobs_to_wait_for;
    @jobs = grep { $_->{state} eq 'COMPLETE' || $_->{state} eq 'REAPED'} @jobs_to_wait_for;
  }
  $jobs[0]->mark_reaped;
  return $jobs[0]->{real_pid};
}

# wait on any process from a specific process group
sub _waitpid_pgrp {
  my ($no_hang, $reap_bg_ok, $target, $timeout) = @_;
  my $expire = Time() + ($timeout || 864000);
  my ($pid, $nactive) = _reap($reap_bg_ok,$target);
  unless ($no_hang) {
    while (!isValidPid($pid) && $nactive > 0) {
      if (Time() >= $expire) {
	return TIMEOUT;
      }
      pause();
      ($pid, $nactive) = _reap($reap_bg_ok,$target);
    }
  }
  $? = $ALL_JOBS{$pid}->{status}
    if defined $ALL_JOBS{$pid};
  return $pid;
}

#
# bastards arise when a child finishes quickly and has been
# reaped in the SIGCHLD handler before the parent has finished
# initializing the job's state.   See  Forks::Super::Sigchld::handle_CHLD() .
#
sub _handle_bastards {
  foreach my $pid (keys %Forks::Super::BASTARD_DATA) {
    my $job = $ALL_JOBS{$pid};
    if (defined $job) {
      $job->mark_complete;
      ($job->{end}, $job->{status}) =
	\@{delete $Forks::Super::BASTARD_DATA{$pid}};

    }
  }
}

1;
