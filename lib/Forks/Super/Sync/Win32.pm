package Forks::Super::Sync::Win32;
use strict;
use warnings;
use Carp;
use Time::HiRes;
use POSIX ':sys_wait_h';
use Win32::Semaphore;

our @ISA = qw(Forks::Super::Sync);
our $VERSION = '0.58';
our $NOWAIT_YIELD_DURATION = 50;
my @RELEASE_ON_EXIT = ();

# Something we have to watch out for is a process dying without
# releasing the resources that it possessed. We have three
# defences against this issue below.
#
# 1. call CORE::kill 0, ... to see if other proc is still alive
# 2. check $!{EINVAL} (Win) and $!{ESRCH} (Cyg) to see if wait call failed
# 3. release resources in a DESTROY block (and  remove  func, though that
#    probably doesn't help that much)

$Forks::Super::Config::CONFIG{'Win32::Semaphore'} = 1;

my $sem_id = 0;

sub new {
    my ($pkg, $count, @initial) = @_;
    my $self = bless {}, $pkg;
    $self->{count} = $count;
    $self->{initial} = [ @initial ];
    $self->{id} = $sem_id++;

    # initial value of 1 means that resource is available
    $self->{sem} = [ map { Win32::Semaphore->new(1,1) } 1..$count ];

    # initial value of 0 means that resource is locked.
    # after fork (in &releaseAfterFork), parent will release {parent_sync}
    # and child will release {child_sync}
    $self->{parent_sync} = Win32::Semaphore->new(0,1);
    $self->{child_sync} = Win32::Semaphore->new(0,1);
    $self->{ppid} = $$;
    $self->{acquired} = [];

    return $self;
}

sub releaseAfterFork {
    my ($self, $childPid) = @_;

    $self->{childPid} = $childPid;
    my $label = $$ == $self->{ppid} ? 'P' : 'C';
    if ($label eq 'P') {
	$self->{parent_sync}->release();
	$self->{child_sync}->wait();
    } elsif ($label eq 'C') {
	$self->{child_sync}->release();
	$self->{parent_sync}->wait();
    }

    for my $i (0 .. $self->{count} - 1) {
	if ($self->{initial}[$i] ne $label) {
	    $self->release($i);
	} else {
	    $self->acquire($i,0);
	}
    }

    if ($label eq 'C') {
	$self->{parent_sync}->release();
	$self->{child_sync}->wait();
	$self->{child_sync}->release();
    } elsif ($label eq 'P') {
	$self->{child_sync}->release();
	$self->{parent_sync}->wait();
	$self->{parent_sync}->release();
    }
    return;
}

# more robust version of Win32::Semaphore->wait.
# detects when partner process has died without releasing the semaphore
# return true if successfully waited on lock
sub _wait_on {
    my ($self, $n, $expire) = @_;
    return 1 if !$self->{sem};
    my $partner = $$ == $self->{ppid} ? $self->{childPid} : $self->{ppid};
    while (1) {
	local $! = 0;
	my $nk = CORE::kill 0, $partner;
	if (!$nk) {
	    carp "sync::_wait_on thinks $partner is gone";
	    $self->{skip_wait_on} = 1;
	    delete $self->{sem};
	    return 3;
	}

	my $z = $self->{sem} && $self->{sem}[$n]->wait($NOWAIT_YIELD_DURATION);
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
    if ($n < 0 || $n >= $self->{count}) {
	return;
    }
    if ($self->{acquired}[$n]) {
	return -1;
    }

    # XXX - need to handle the case where the partner process has died
    #       without releasing a lock

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
}

sub release {
    my ($self, $n) = @_;
    if ($n < 0 || $n >= $self->{count}) {
	return;
    }
    if (!$self->{acquired}[$n]) {
	return 0;
    }
    $self->{acquired}[$n] = 0;
    return $self->{sem} && $self->{sem}[$n] && $self->{sem}[$n]->release();
}

sub remove {
    my $self = shift;
    $self->release($_) for 0 .. $self->{count} - 1;
    $self->{sem} = [];
}

sub DESTROY {
    my $self = shift;
    $self->release($_) for 0 .. $self->{count}-1;
    $self->{sem} = [];
}

1;

=head1 NAME

Forks::Super::Sync::Win32
- Forks::Super sync object using Win32::Semaphore

=head1 SYNOPSIS

    $lock = Forks::Super::Sync->new(implementation => 'Win32', ...);

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

IPC synchronization object implemented with L<Win32::Semaphore>.

Advantages: fast, doesn't create files or use filehandles

Disadvantages: Windows only.

=head1 SEE ALSO

L<Forks::Super::Sync>

=cut

