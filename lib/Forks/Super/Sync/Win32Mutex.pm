package Forks::Super::Sync::Win32Mutex;
use Win32::Mutex;
use Win32::Semaphore;
use Forks::Super::Sync::Semaphlock;
use Carp;
use POSIX ':sys_wait_h';
use strict;
use warnings;

our @ISA = qw(Forks::Super::Sync);
our $VERSION = '0.57';
our $NOWAIT_YIELD_DURATION = 50; # ms

# Something we have to watch out for is a process dying without
# releasing the resources that it possessed. We have three
# defences against this issue below.
#
# 1. call CORE::kill 0, ... to see if other proc is still alive
# 2. 
# 3. release resources in a DESTROY block (and  remove  func, though that
#    probably doesn't help that much)

sub new {
    my ($pkg, $count, @initial) = @_;
    my $self = bless {}, $pkg;
    $self->{count} = $count;
    $self->{initial} = [ @initial ];

    # use Semaphlock to manage sync in  releaseAfterFork, since I don't have
    # a handle on what happens to a Win32::Mutex across a fork
    $self->{isync} = Forks::Super::Sync->new(
	implementation => 'Semaphlock',
	count => "0E0", initial => [],
	);

    $self->{mutex} = [ map { Win32::Mutex->new(0) } 1 .. $count ];

    return $self;
}

sub releaseAfterFork {
    my ($self, $childPid) = @_;
    $self->{childPid} = $childPid;
    my $label = $self->{label} = $$ == $self->{ppid} ? 'P' : 'C';

    for my $n (0 .. $self->{count} - 1) {
	if ($self->{initial}[$n] eq $label) {
	    $self->acquire($n);
	}
    }

    $self->{isync}->releaseAfterFork;

    if (0) {


    if ($label eq 'P') {
	$self->{isync}->release(0);
	$self->{isync}->acquireAndRelease(1);
    } else {
	$self->{isync}->release(1);
	$self->{isync}->acquireAndRelease(0);
    }
    }
}

# more robust version of Win32::Mutex->wait.
# detects when partner process has died without releasing the mutex
# return true if successfully waited on lock
sub _wait_on {
    my ($self, $n, $expire) = @_;
    return 1 if !$self->{mutex};
    my $partner = $$ == $self->{ppid} ? $self->{childPid} : $self->{ppid};
    while (1) {
	local $! = 0;
	my $nk = CORE::kill 0, $partner;
	if (!$nk) {
	    carp "sync::_wait_on thinks $partner is gone";
	    $self->{skip_wait_on} = 1;
	    delete $self->{mutex};
	    return 3;
	}

	my $z = $self->{mutex} && $self->{mutex}[$n]->wait($NOWAIT_YIELD_DURATION);
	if ($z) {
	    return 1;
	}
	# $!{ERROR_BAD_COMMAND} is a Windows thing
	if ($!{EINVAL} || $!{ESRCH} || $!{ERROR_BAD_COMMAND}) {
	    carp "sync::_wait_on: \$!=$!";
	    return 2;
	} 
	elsif ($!) {
	    carp "\$! is ",0+$!," $! ",0+$^E," $^E ",
	        join(",", grep { $!{$_} } sort keys %!), "\n";
	}

	if ($expire > 0 && Time::HiRes::time() >= $expire) {
	    return 0;
	}
	waitpid -1, &WNOHANG;
    }
}

sub acquire {
    my ($self, $n, $timeout) = @_;
    return if $n < 0 || $n >= $self->{count};
    return -1 if $self->{acquired}[$n];

    my $expire = -1;
    if (defined $timeout) {
	$expire = Time::HiRes::time() + $timeout;
    }
    my $z = $self->_wait_on($n, $expire);
    if ($z > 0) {
	$self->{acquired}[$n] = 1;
	return 1;
    } else {
	$self->{acquired}[$n] = 0;
	return 0;
    }

=deprecated

    if (defined $timeout) {
	$z = $self->{mutex}[$n]->wait(1000 * $timeout);
    } else {
	$z = $self->{mutex}[$n]->wait;
    }
    if ($z) {

	$self->{acquired}[$n] = 1;
    }
    return $z;

=cut

}

sub release {
    my ($self, $n) = @_;
    return unless $n >= 0 && $n < $self->{count};
    return 0 unless $self->{acquired}[$n];


    my $z = $self->{mutex}[$n]->release;
    if ($z) {
	$self->{acquired}[$n] = 0;
    } else {
	carp "Win32Mutex release error: $^E";
    }
    return $z;
}

sub remove {
    $_[0]->DESTROY;
}

sub DESTROY {
    my $self = shift;
    $self->release($_) for 0 .. $self->{count}-1;
    $self->{mutex} = [];
}


1;

=head1 NAME

Forks::Super::Sync::Win32::Mutex

=head1 SYNOPSIS

    $lock = Forks::Super::Sync->new(implementation => 'Win32Mutex', ...);
    $lock = Forks::Super::Sync->new(implementation => 'Win32::Mutex', ...);

    $pid=fork();
    $lock->releaseAfterFork();

    if ($pid == 0) { # child code
       $lock->acquire(...);
       $lock->release(...);
    } else {
       $lock->acquire(...);
       $lock->release(...);
    }

=head1 DESCRIPTION

IPC synchronization object implemented with L<Win32::Mutex>.

Advantages: fast, doesn't create files or use filehandles

Disadvantages: Windows only. Gets complicated when a process dies without
releasing its locks.

=head1 SEE ALSO

L<Forks::Super::Sync>

=cut

