#
# Forks::Super::Wait - implementation of Forks::Super:: wait, waitpid,
#        and waitall methods
#

package Forks::Super::Wait;
use Forks::Super::Job;
use Forks::Super::Util qw(is_number isValidPid pause IS_WIN32);
use Forks::Super::Debug qw(:all);
use Forks::Super::Config;
use Forks::Super::Queue;
use Forks::Super::SysInfo;
use Forks::Super::Tie::Enum;
use POSIX ':sys_wait_h';
use Exporter;
use Carp;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(wait waitpid waitall TIMEOUT WREAP_BG_OK);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our $VERSION = '0.53';

our ($productive_pause_code, $productive_waitpid_code);


# 5.8 compatible function equivalent to 5.10's  $x // $y  construction
sub _defined_or {
    my ($target, $default) = @_;
    return defined($target) ? $target : $default;
}

# What should  waitpid  return for certain inputs, including bogus, inputs,
# and what are the side-effects on $? ?
my ($ACTIVE_WAITPID_RESULT, $ACTIVE_WAITPID_STATUS,
    $REAPED_WAITPID_RESULT, $REAPED_WAITPID_STATUS,
    $BOGUS_WAITPID_RESULT, $BOGUS_WAITPID_STATUS) =
    (_defined_or($Forks::Super::SysInfo::ACTIVE_WAITPID_RESULT, 0),
     _defined_or($Forks::Super::SysInfo::ACTIVE_WAITPID_STATUS, -1),
     _defined_or($Forks::Super::SysInfo::REAPED_WAITPID_RESULT, -1),
     _defined_or($Forks::Super::SysInfo::REAPED_WAITPID_STATUS, -1),
     _defined_or($Forks::Super::SysInfo::BOGUS_WAITPID_RESULT, -1),
     _defined_or($Forks::Super::SysInfo::BOGUS_WAITPID_STATUS, -1));

tie our $WAIT_ACTION_ON_SUSPENDED_JOBS, 
    'Forks::Super::Tie::Enum', qw(wait fail resume);

sub set_productive_pause_code (&) {
    $productive_pause_code = shift;
    return;
}
sub set_productive_waitpid_code (&) {
    $productive_waitpid_code = shift;
    return;
}

use constant TIMEOUT => -1.5;
use constant ONLY_SUSPENDED_JOBS_LEFT => -1.75;
use constant WREAP_BG_OK => WNOHANG() << 1;

sub wait {
    my $timeout = shift || 0;
    $timeout = 1E-6 if $timeout < 0;

    # print STDERR "invoked Forks::Super::wait  (\$DEBUG=$DEBUG)\n";

    debug("invoked Forks::Super::wait") if $DEBUG;
    return Forks::Super::Wait::waitpid(-1, 0, $timeout);
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
	debug("waitpid: dispatching _waitpid_any") if $DEBUG;
	return _waitpid_any($no_hang, $reap_bg_ok, $timeout);
    }
    if (defined $ALL_JOBS{$target}) {
	debug("waitpid: dispatching _waitpid_target") if $DEBUG;
	return _waitpid_target($no_hang, $reap_bg_ok, $target, $timeout);
    }
    if (0 < (my @wantarray = Forks::Super::Job::getByName($target))) {
	debug("waitpid: dispatching _waitpid_name") if $DEBUG;
	return _waitpid_name($no_hang, $reap_bg_ok, $target, $timeout);
    }
    if (!is_number($target)) {
	debug("waitpid: bogus target") if $DEBUG;
	return _bogus_waitpid_result();
    }
    if ($target > 0) {
	debug("waitpid: bogus target") if $DEBUG;
	return _bogus_waitpid_result();
    }
    if ($Forks::Super::SysInfo::CONFIG{'getpgrp'}) {
	if ($target == 0) {
	    unless (eval { $target = getpgrp(0) } ) {
		$target = -$$;
	    }
	} else {
	    $target = -$target;
	}
	debug("waitpid: dispatching _waitpid_pgrp") if $DEBUG;
	return _waitpid_pgrp($no_hang, $reap_bg_ok, $target, $timeout);
    } else {
	debug("waitpid: bogus (pgid) target") if $DEBUG;
	return _bogus_waitpid_result();
    }
}

sub waitall {
    my $timeout = shift || 9E9;  # 285 years should be long enough to wait
    $timeout = 1E-6 if $timeout < 0;
    my $waited_for = 0;
    my $expire = Time::HiRes::time() + $timeout ;
    debug("waitall: waiting on all procs") if $DEBUG;
    my $pid;
    do {
	# $productive_waitpid_code->() if $productive_waitpid_code;
	$pid = Forks::Super::Wait::wait($expire - Time::HiRes::time());
	if ($DEBUG) {
	    debug("waitall: caught pid $pid");
	}
    } while isValidPid($pid,1) 
	&& ++$waited_for 
	&& Time::HiRes::time() < $expire;

    return $waited_for;
}

# is return value from _reap/waitpid/wait a simple scalar or an
# overloaded Forks::Super::Job object?

our $OVERLOAD_RETURN;
sub _reap_return {
    my ($job) = @_;
    if (!defined $OVERLOAD_RETURN) {
	$OVERLOAD_RETURN = $Forks::Super::Job::OVERLOAD_ENABLED;
    }

    my $pid = $job->{real_pid};
    return $OVERLOAD_RETURN ? Forks::Super::Job::get($pid) : $pid;
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
    Forks::Super::Sigchld::handle_bastards();

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
    debug('_reap(): found ', scalar @waiting,
	  ' complete & unreaped processes') if $DEBUG;

    if (@waiting > 0) {
	@waiting = sort { $a->{end} <=> $b->{end} } @waiting;
	my $job = shift @waiting;
	my $real_pid = $job->{real_pid};
	my $pid = $job->{pid};

	if ($job->{debug}) {
	    debug("_reap: reaping $pid/$real_pid.");
	}
	if (not wantarray) {
	    return _reap_return($job);
	}

	my ($nactive1, $nalive, $nactive2, $nalive2)
	    = Forks::Super::Job::count_processes($reap_bg_ok, $optional_pgid);
	debug("_reap:  $nalive remain.") if $DEBUG;
	$job->_mark_reaped;
	return (_reap_return($job), $nactive1, $nalive, $nactive2, $nalive2);
    }


    # the failure to reap active jobs may occur because the jobs are still
    # running, or it may occur because the relevant signals arrived at a
    # time when the signal handler was overwhelmed

    my ($nactive1, $nalive, $nactive2, $nalive2)
	= Forks::Super::Job::count_processes($reap_bg_ok, $optional_pgid);

    my $val = $nalive2 ? _active_waitpid_result() : _reaped_waitpid_result();
    return $val if not wantarray;

    if ($DEBUG) {
	debug("_reap(): nothing to reap now. $nactive1 remain.");
    }
    return ($val, $nactive1, $nalive, $nactive2, $nalive2);
}


# wait on any process
sub _waitpid_any {
    my ($no_hang,$reap_bg_ok,$timeout) = @_;
    my $expire = Time::HiRes::time() + ($timeout || 9E9);
    my ($pid, $nactive2, $nalive, $nactive, $nalive2) = _reap($reap_bg_ok);
    if ($no_hang == 0) {
	while (!isValidPid($pid,1) && $nalive > 0) {
	    if (Time::HiRes::time() >= $expire) {
		# XXX - reset $? ?
		return TIMEOUT;
	    }
	    if ($nactive == 0) {

		if ($WAIT_ACTION_ON_SUSPENDED_JOBS eq 'fail') {
		    # XXX - reset $? ?
		    return ONLY_SUSPENDED_JOBS_LEFT;
		} elsif ($WAIT_ACTION_ON_SUSPENDED_JOBS eq 'resume') {
		    _active_one_suspended_job($reap_bg_ok);
		}
	    }
	    $productive_waitpid_code->() if $productive_waitpid_code;
	    pause();
	    ($pid, $nactive2, $nalive, $nactive, $nalive2) = _reap($reap_bg_ok);
	}
    }
    if (defined $ALL_JOBS{$pid}) {
	my $job = Forks::Super::Job::get($ALL_JOBS{$pid});
	pause() while not defined $job->{status};
	$? = $job->{status};
    }
    return $pid;
}

sub _active_one_suspended_job {
    my @suspended = grep { $_->{state} eq 'SUSPENDED' } @Forks::Super::ALL_JOBS;
    if (@suspended == 0) {
	@suspended = grep { 
	    $_->{state} =~ /SUSPENDED/
	} @Forks::Super::ALL_JOBS;
    }
    @suspended = sort { 
	$b->{queue_priority} <=> $a->{queue_priority} } @suspended;
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

sub _bogus_waitpid_result {
    if (defined $BOGUS_WAITPID_STATUS) {
	$? = $BOGUS_WAITPID_STATUS;
    }
    return $BOGUS_WAITPID_RESULT;
}

sub _active_waitpid_result {
    if (defined $ACTIVE_WAITPID_STATUS) {
	$? = $ACTIVE_WAITPID_STATUS;
    }
    return $ACTIVE_WAITPID_RESULT;
}

sub _reaped_waitpid_result {
    if (defined $REAPED_WAITPID_STATUS) {
	$? = $REAPED_WAITPID_STATUS;
    }
    return $REAPED_WAITPID_RESULT;
}

# wait on a specific process
sub _waitpid_target {
    my ($no_hang, $reap_bg_ok, $target, $timeout) = @_;
    my $expire = Time::HiRes::time() + ($timeout || 9E9);

    #Forks::Super::handle_CHLD(-1);

    my $job = $ALL_JOBS{$target};
    if (not defined $job) {
	debug("_waitpid_target: bogus target") if $job->{debug} & 2;
	return _bogus_waitpid_result();
    }
    if ($job->{state} eq 'COMPLETE') {
	debug("_waitpid_target: job $job is complete, reaping ...")
	    if $job->{debug} & 2;
	$job->_mark_reaped;
	return _reap_return($job);
    } elsif ($job->{daemon}) {
	debug("_waitpid_target: job $job is a daemon, returning bogus result")
	    if $job->{debug} & 2;
	return _bogus_waitpid_result();
    } elsif ($job->{state} eq 'REAPED') {
	debug("_waitpid_target: job $job is already reaped ...") 
	    if $job->{debug} & 2;
	return _reaped_waitpid_result();
    } elsif ($no_hang) {
	debug("_waitpid_target: job $job is still $job->{state}")
	    if $job->{debug} & 2;
	return _active_waitpid_result();
    } else {
	# block until job is complete.
	debug("_waitpid_target: blocking until $job is complete")
	    if $job->{debug} & 2;
	while ($job->{state} ne 'COMPLETE' and $job->{state} ne 'REAPED') {
	    if (Time::HiRes::time() >= $expire) {
		# XXX - update $? ?
		return TIMEOUT;
	    }
	    $productive_waitpid_code->() if $productive_waitpid_code;
	    pause();
	    #Forks::Super::Sigchld::handle_CHLD(-1) if &IS_WIN32;
	    if ($job->{state} =~ /DEFER|SUSPEND/) {
		Forks::Super::Queue::check_queue();
	    }
	}
	debug("_waitpid_target: job $job is complete now, reaping ...")
	    if $job->{debug} & 2;
	$job->_mark_reaped;
	return _reap_return($job);
    }
}

sub _waitpid_name {
    my ($no_hang, $reap_bg_ok, $target, $timeout) = @_;
    my $expire = Time::HiRes::time() + ($timeout || 9E9);
    my @jobs = Forks::Super::Job::getByName($target);
    if (@jobs == 0) {
	return _bogus_waitpid_result();
    }
    my @jobs_to_wait_for = ();
    foreach my $job (@jobs) {
	if ($job->{state} eq 'COMPLETE') {
	    $job->_mark_reaped;
	    return _reap_return($job);
	} elsif ($job->{state} ne 'REAPED' 
		 && $job->{state} ne 'DEFERRED'
		 && !$job->{daemon}) {
	    push @jobs_to_wait_for, $job;
	}
    }
    if (@jobs_to_wait_for == 0) {
	return _reaped_waitpid_result();
    } elsif ($no_hang) {
	return _active_waitpid_result();
    }

    # otherwise block until a job is complete
    @jobs = grep {
	$_->{state} eq 'COMPLETE' || $_->{state} eq 'REAPED'
    } @jobs_to_wait_for;
    while (@jobs == 0) {
	if (Time::HiRes::time() >= $expire) {
	    # XXX - update $? ?
	    return TIMEOUT;
	}
	$productive_waitpid_code->() if $productive_waitpid_code;
	pause();
	Forks::Super::Queue::run_queue()
	    if grep {$_->{state} eq 'DEFERRED'} @jobs_to_wait_for;
	@jobs = grep { $_->{state} eq 'COMPLETE' 
			   || $_->{state} eq 'REAPED'} @jobs_to_wait_for;
    }
    $jobs[0]->_mark_reaped;
    return _reap_return($jobs[0]);
}

# wait on any process from a specific process group
sub _waitpid_pgrp {
    my ($no_hang, $reap_bg_ok, $target, $timeout) = @_;
    my $expire = Time::HiRes::time() + ($timeout || 9E9);
    my ($pid, $nactive) = _reap($reap_bg_ok,$target);
    unless ($no_hang) {
	while (!isValidPid($pid,1) && $nactive > 0) {
	    if (Time::HiRes::time() >= $expire) {
		# XXX - update $? ?
		return TIMEOUT;
	    }
	    $productive_waitpid_code->() if $productive_waitpid_code;
	    pause();
	    ($pid, $nactive) = _reap($reap_bg_ok,$target);
	}
    }
    $? = $ALL_JOBS{$pid}->{status}
        if defined $ALL_JOBS{$pid};
    return $pid;
}

1;
