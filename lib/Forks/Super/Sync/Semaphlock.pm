package Forks::Super::Sync::Semaphlock;
use strict;
use warnings;
use Carp;
use Time::HiRes;
our $VERSION = '0.64';
our @ISA = qw(Forks::Super::Sync);

my $ipc_seq = 0;
my $sync_count = 0;

sub new {
    my ($pkg, $count, @initial) = @_;
    my $self = bless {}, $pkg;
    $self->{count} = $count;
    $self->{initial} = [ @initial ];
    $self->{id} = $sync_count++;
    bless $self, $pkg;

    # meta locks
    $self->{child_sync} = _get_filename();
    $self->_register_ipc_file($self->{child_sync}, "for child");
    $self->{parent_sync} = _get_filename();
    $self->_register_ipc_file($self->{parent_sync}, "for parent");

    # lock these file descriptors before the fork. The locks will persist
    # through the fork, and can be unlocked by either parent or child
    open $self->{child_lock}, '>>', $self->{child_sync};
    flock $self->{child_lock}, 2;
    open $self->{parent_lock}, '>>', $self->{parent_sync};
    flock $self->{parent_lock}, 2;

    for my $i (0 .. $count-1) {
	my $file = _get_filename();
	$self->_register_ipc_file($file, "count $i");
	if (open my $fh, '>>', $file) {
	    $self->{files}[$i] = $file;
	    close $fh;
	} else {
	    carp "could not use $file as a synchronization file: $!";
	}
    }

    return $self;
}

sub _register_ipc_file {
    my ($self, $filename, $i) = @_;
    if (defined &Forks::Super::Job::Ipc::_register_ipc_file) {
      Forks::Super::Job::Ipc::_register_ipc_file(
	  $filename, [ purpose => "sync object id $self->{id} $i" ]);
    } else {
	$self->{unlink} ||= [];
	push @{$self->{unlink}}, $filename;
    }
    return;
}

sub _touch {
  my $file = shift;
  open my $touch, '>>', $file;
  close $touch;
}

sub releaseAfterFork {
    my $self = shift;

    # for this implementation, it is more like acquire after fork
    my $label = $$ == $self->{ppid} ? 'P' : 'C';

    my $wait = time + 5.0;
    if ($label eq 'P') {
      _touch( $self->{parent_sync} . "1" );
      until (time > $wait || -e $self->{child_sync} . "1") {
	sleep 0.05;
      }
      if (! -e $self->{child_sync} . "1") {
	warn "child not synchronized for parent-child sync init";
      }
    } elsif ($label eq 'C') {
      _touch( $self->{child_sync} . "1" );
      until (time > $wait || -e $self->{parent_sync} . "1") {
	sleep 0.05;
      }
      if (! -e $self->{parent_sync} . "1") {
	warn "parent not synchronized for parent-child sync init";
      }
    }

    for my $i (0 .. $self->{count} - 1) {
	if ($self->{initial}[$i] eq $label) {
	    my $file = $self->{files}[$i];
	    if ($file) {
		my $fh;
		if (!open $fh, '>>', $file) {
		    carp 'FS::Sync::Semaphlock::releaseAfterFork: ',
		        "error acquiring resource $i in $label";
		    next;
		}
		flock $fh, 2;
		$self->{acquired}[$i] = $fh;
	    } else {
		carp 'FS::Sync::Semaphlock::releaseAfterFork: ',
		    "no resource $i $file to acquire in $label";
	    }
	}
    }

    $wait = time + 5.0;
    if ($label eq 'P') {
      _touch( $self->{parent_sync} . "2" );
      while (! -e $self->{child_sync} . "2") {
	if (time > $wait) {
	  warn "child not synchronized for end of parent-child init";
	  last;
	}
	sleep 0.1;
      }
      unlink $self->{parent_sync} . "1", $self->{parent_sync} . "2";
    } elsif ($label eq 'C') {
      _touch( $self->{child_sync} . "2" );
      while (! -e $self->{parent_sync} . "2") {
	if (time > $wait) {
	  warn "parent not synchronized for end of parent-child init";
	  last;
	}
	sleep 0.1;
      }
      unlink $self->{child_sync} . "1", $self->{child_sync} . "2";
    }

    if ($label eq 'P') {

	flock $self->{parent_lock}, 8;

	open my $fh, '>>', $self->{child_sync};
	flock $fh, 2;

	close $fh;
	close $self->{parent_lock};
	close $self->{child_lock};
	unlink $self->{parent_sync}, $self->{child_sync};

    } else {

	flock $self->{child_lock}, 8;

	open my $fh, '>>', $self->{parent_sync};
	flock $fh, 2;

    }

    # Since this implementation does not lock any resources until
    # AFTER the fork, there is a race condition. It is possible
    # for the companion process to try and successfully acquire a
    # resource before the intended process is able to run this
    # method and acquire it for itself.
    #
    # A delay here is not fool proof, but it should help the
    # companion process have enough time to grab the resources
    # it is supposed to before this process gets on with its
    # business.
####    sleep 5;

    return;
}

sub release {
    my ($self, $n) = @_;
    return if $n<0 || $n>=$self->{count};
    if (defined $self->{acquired}[$n]) {
	my $z = flock $self->{acquired}[$n], 8;	
	$self->{acquired}[$n] = undef;
	return $z;
    }
    return;
}

sub acquire {
    my ($self, $n, $timeout) = @_;
    return if $n<0 || $n>=$self->{count};
    my $file = $self->{files}[$n];
    if (defined $self->{acquired}[$n]) {
	return -1;
    }
    my $fh;
    if (!open $fh, '>>', $file) {
	carp "no file resource $file available to acquire: $!";
	return;
    }
    if (defined $timeout) {
	my $expire = Time::HiRes::time() + $timeout;
	my $z;
	do {
	    $z = flock $fh, 6;
	    if ($z) {
		$self->{acquired}[$n] = $fh;
		return $z;
	    }
	    if ($timeout > 0.0) {
		Time::HiRes::sleep(0.01);
	    }
	} while (Time::HiRes::time() < $expire);
	close $fh;
	return 0;
    }

    # no timeout
    my $z = flock $fh, 2;
    if ($z) {
	$self->{acquired}[$n] = $fh;
    }
    return $z;
}

sub DESTROY {
    my $self = shift;
    $self->release($_) for 0 .. $self->{count}-1;
    $self->{acquired} = [];
    unlink @{$self->{unlink}} if $self->{unlink};
    $self->{files} = [];
}

sub _get_filename {
    return sprintf "%s/.sync%03d", $Forks::Super::IPC_DIR, $ipc_seq++;
}

sub remove {
    my $self = shift;
    # XXXXXX
    foreach my $fh (@{$self->{acquired}}) {
	if ($fh) {
	    close $fh;
	}
    }
    delete $self->{count};
    $self->{fh} = [];
}

1;

__END__

=head1 NAME

Forks::Super::Sync::Semaphlock
- Forks::Super sync object using advisory file locking

=head1 SYNOPSIS

    $lock = Forks::Super::Sync->new(implementation => 'Semaphlock', ...);

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

IPC synchronization object implemented with advisory file locking.
Useful as a last resort if your system does not have good
support for semaphores or shared memory.

Advantages: should work anywhere that implements L<perlfunc/flock>.

Disadvantages: creates files, IPC litter. Uses precious filehandles.

=head1 SEE ALSO

L<Forks::Super::Sync>

=cut

