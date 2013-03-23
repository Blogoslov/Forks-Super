package Forks::Super::Sync::IPCSemaphore;
use strict;
use warnings;
use Carp;
use Time::HiRes;
use POSIX ':sys_wait_h';
use IPC::SysV qw(IPC_PRIVATE S_IRUSR S_IWUSR IPC_CREAT IPC_NOWAIT);
use IPC::Semaphore;
our @ISA = qw(Forks::Super::Sync);
our $VERSION = '0.64';

our $NOWAIT_YIELD_DURATION = 0.05;

my @RELEASE_ON_EXIT = ();

sub new {
    my ($pkg, $count, @initial) = @_;

    if ($^O eq 'MSWin32' || $^O eq 'cygwin') {
	return;
    }

    my $self = bless{ count => $count, initial => [ @initial ] }, $pkg;

    $self->{sems} = eval q{
	IPC::Semaphore->new(
	    &IPC_PRIVATE, 4+$count, &S_IRUSR|&S_IWUSR|&IPC_CREAT);
    };
    unless ($self->{sems}) {
	carp "IPC::Semaphore constructor failed: $@";
	return;
    }
    $self->{sems}->setall(1,1,1,1,(0) x $count);
    return $self;
}

sub releaseAfterFork {
    my ($self, $childPid) = @_;

    $self->{childPid} = $childPid;
    my $label = $self->{label} = $$ == $self->{ppid} ? "P" : "C";
    for my $i (0 .. $self->{count}-1) {
	if ($self->{initial}[$i] eq $label) {
	    $self->acquire($i);
	}
    }
    if ($label eq "P") {
	$self->release(-3);            # indicate parent is ready
	$self->acquireAndRelease(-2);  # wait for child to be ready
    } elsif ($label eq 'C') {
	push @RELEASE_ON_EXIT, $self; # if rand() > 0.5;
	$self->release(-2);
	$self->acquireAndRelease(-3);
    }
    return;
}

sub release {
    my ($self, $n) = @_;
    return if $n+4 < 0 || $n >= $self->{count};
    if ($n < 0 || $self->{acquired}[$n]) {
	$self->{sems} && $self->{sems}->setval($n+4, 0);
	$self->{acquired}[$n] = 0  if $n >= 0;
	return 1;
    }
    return;
}

# robuster version of  $self->{sems}->op($n,0,FLAGS)
# detects when partner process has died without removing the semaphore
# return true if successfully waited on lock
sub _wait_on {
    my ($self, $n, $expire) = @_;
    return 1 if !$self->{sems};

    my $partner = $$ == $self->{ppid} ? $self->{childPid} : $self->{ppid};

    while (1) {
	local $! = 0;
	my $nk = $partner && CORE::kill 0, $partner;
	if (!$nk) {
	    carp "sync::_wait_on thinks that $partner is gone ...return 3.1";
	    $self->{skip_wait_on} = 1;
	    delete $self->{sems};
	    return 3.1;
	}

	my $z = $self->{sems} && $self->{sems}->op($n, 0, &IPC_NOWAIT);

#	@! = grep { $!{$_} } keys %!;

	if ($z) {
	    return 1;
	} elsif ($!{EINVAL}) {  # semaphore was removed

	    carp "sync::_wait_on: \$!=Invalid resource ... return 2";
	    return 2;
	}

	if ($expire > 0 && Time::HiRes::time() >= $expire) {
	    return 0;
	}

	# sem value not zero. Is the process that partner process still alive?
	if (!CORE::kill(0, $partner)) {
	    carp "sync::_wait_on thinks that $partner is gone ...return 3";
	    $self->{skip_wait_on} = 1;
	    delete $self->{sems};
	    return 3;
	}
	Time::HiRes::sleep( $NOWAIT_YIELD_DURATION );
	waitpid -1, &WNOHANG;
    }
}

sub acquire {
    my ($self, $n, $timeout) = @_;
    if ($n+4 < 0 || $n >= $self->{count}) {
	return;
    }
    if ($n >= 0 && $self->{acquired}[$n]) {
	return -1; # already acquired
    }


    my $expire = -1;
    if (defined $timeout) {
	$expire = Time::HiRes::time() + $timeout;
    }
    my $z = $self->_wait_on($n+4, $expire);
    if ($z > 0) {
	if ($n >= 0) {
	    $self->{acquired}[$n] = 1;
	}
	$self->{sems} && $self->{sems}->setval($n+4,1);
    }

    if ($z > 1) {
	return "1";
	return "0 but true";
    }
    return $z;
}

END {
    foreach my $sync (@RELEASE_ON_EXIT) {
	$sync->release($_) for 0 .. $sync->{count} - 1;
	$sync->{sems} && $sync->{sems}->remove;
    }
}

1;

=head1 NAME

Forks::Super::Sync::IPCSemaphore
- Forks::Super sync object using SysV semaphores

=head1 SYNOPSIS

    $lock = Forks::Super::Sync->new(implementation => 'IPCSemaphore', ...);

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

IPC synchronization object implemented with SysV semaphores.

Advantages: fast, doesn't create files or use filehandles

Disadvantages: Unix only. Gets complicated when a child process dies
without releasing its locks.

=head1 SEE ALSO

L<Forks::Super::Sync>

=cut

