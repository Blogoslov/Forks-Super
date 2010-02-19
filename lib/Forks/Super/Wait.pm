package Forks::Super::Wait;
use Forks::Super::Job;
use Forks::Super::Util qw(is_number isValidPid pause);
use Forks::Super::Debug qw(:all);
use Forks::Super::Config;
use Forks::Super::Queue;
use POSIX ':sys_wait_h';
use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our @EXPORT_OK = qw(wait waitpid waitall);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our ($productive_pause_code, $productive_waitpid_code);
our $REAP_NOTHING_MSGS = 0;

sub set_productive_pause_code (&) {
  $productive_pause_code = shift;
}
sub set_productive_waitpid_code (&) {
  $productive_waitpid_code = shift;
}

sub wait {
  debug("invoked Forks::Super::wait") if $DEBUG;
  return Forks::Super::Wait::waitpid(-1,0);
}

sub waitpid {
  my ($target,$flags,@dummy) = @_;
  $productive_waitpid_code->() if $productive_waitpid_code;

  if (@dummy > 0) {
    carp "Forks::Super::waitpid: Too many arguments\n";
    foreach my $dflag (@dummy) {
      $flags |= $dflag;
    }
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
  if (is_number($target) && $target == -1) {
    return _waitpid_any($no_hang);
  } elsif (defined $ALL_JOBS{$target}) {
    return _waitpid_target($no_hang, $target);
  } elsif (0 < (my @wantarray = Forks::Super::Job::getByName($target))) {
    return _waitpid_name($no_hang, $target);
  } elsif (!is_number($target)) {
    return -1;
  } elsif ($target > 0) {
    # invalid pid
    return -1;
  } elsif (Forks::Super::Config::CONFIG("getpgrp")) {
    if ($target == 0) {
      $target = getpgrp(0);
    } else {
      $target = -$target;
    }
    return _waitpid_pgrp($no_hang, $target);
  } else {
    return -1;
  }
}

sub waitall {
  my $waited_for = 0;
  debug("Forks::Super::waitall(): waiting on all procs") if $DEBUG;
  do {
    $productive_pause_code->() if $productive_pause_code;
  } while isValidPid(Forks::Super::Wait::wait()) && ++$waited_for;
  return $waited_for;   # future enhancement: return 0 or -1 on timeout
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
  my ($optional_pgid) = @_; # to reap procs from specific group
  $productive_waitpid_code->() if $productive_waitpid_code;

  _handle_bastards();

  my @j = @ALL_JOBS;
  @j = grep { $_->{pgid} == $optional_pgid } @ALL_JOBS
    if defined $optional_pgid;

  # see if any jobs are complete (signaled the SIGCHLD handler)
  # but have not been reaped.
  my @waiting = grep { $_->{state} eq 'COMPLETE' } @j;
  debug('Forks::Super::_reap(): found ', scalar @waiting,
    ' complete & unreaped processes') if $DEBUG;

  if (@waiting > 0) {
    @waiting = sort { $a->{end} <=> $b->{end} } @waiting;
    my $job = shift @waiting;
    my $real_pid = $job->{real_pid};
    my $pid = $job->{pid};

    debug("Forks::Super::_reap(): reaping $pid/$real_pid.")
      if $job->{debug};
    return $real_pid if not wantarray;

    my $nactive = grep { $_->{state} eq 'ACTIVE'  or
			   $_->{state} eq 'DEFERRED'  or
			   $_->{state} eq 'SUSPENDED'  or    # for future use
			   $_->{state} eq 'COMPLETE' } @j;

    debug("Forks::Super::_reap(): $nactive remain.") if $DEBUG;
    $job->mark_reaped;
    return ($real_pid, $nactive);
  }

  my @active = grep { $_->{state} eq 'ACTIVE' or
			$_->{state} eq 'DEFERRED' or
			$_->{state} eq 'SUSPENDED' or         # for future use
			$_->{state} eq 'COMPLETE' } @j;


  # the failure to reap active jobs may occur because the jobs are still
  # running, or it may occur because the signal handler was overwhelmed
  if (@active > 0) {
    ++$REAP_NOTHING_MSGS;
    if ($REAP_NOTHING_MSGS % 10 == 0) {
      if (0 && $productive_waitpid_code) {
	$productive_waitpid_code->();
#      } elsif (defined &Forks::Super::handle_CHLD) {
#	Forks::Super::handle_CHLD(-1);
      } elsif (defined $SIG{CHLD} && ref $SIG{CHLD} eq "CODE") {
	$SIG{CHLD}->(-1);
      }
    }
  }

  return -1 if not wantarray;

  my $nactive = @active;

  if ($DEBUG) {
    debug('Forks::Super::_reap(): nothing to reap now. ',
	  "$nactive remain.");
  }

  return (-1, $nactive);
}


# wait on any process
sub _waitpid_any {
  my ($no_hang) = @_;
  my ($pid, $nactive) = _reap();
  unless ($no_hang) {
    while (!isValidPid($pid) && $nactive > 0) {
      pause();
      ($pid, $nactive) = _reap();
    }
  }
  if (defined $ALL_JOBS{$pid}) {
    pause() while not defined $ALL_JOBS{$pid}->{status};
    $? = $ALL_JOBS{$pid}->{status};
  }
  return $pid;
}

# wait on a specific process
sub _waitpid_target {
  my ($no_hang, $target) = @_;
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
      pause();
      Forks::Super::Queue::run_queue() if $job->{state} eq 'DEFERRED';
    }
    $job->mark_reaped;
    return $job->{real_pid};
  }
}

sub _waitpid_name {
  my ($no_hang, $target) = @_;
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
  @jobs = grep { $_->{state} eq 'COMPLETE' || $_->{state} eq 'REAPED' } @jobs_to_wait_for;
  while (@jobs == 0) {
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
  my ($no_hang, $target) = @_;
  my ($pid, $nactive) = _reap($target);
  unless ($no_hang) {
    while (!isValidPid($pid) && $nactive > 0) {
      pause();
      ($pid, $nactive) = _reap($target);
    }
  }
  $? = $ALL_JOBS{$pid}->{status}
    if defined $ALL_JOBS{$pid};
  return $pid;
}

#
# bastards arise when a child finishes quickly and has been
# reaped in the SIGCHLD handler before the parent has finished
# initializing the job's state.   See  Forks::Super::handle_CHLD() .
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


