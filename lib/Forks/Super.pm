package Forks::Super;
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(:all);
use Forks::Super::Config qw(:all);
use Forks::Super::Queue qw(:all);
use Forks::Super::Wait qw(:all);
use Forks::Super::Job;
use Tie::Enum;
use 5.007003;     # for "safe" signals -- see perlipc
use Exporter;
use POSIX ':sys_wait_h';
use Carp;
use File::Path;
use IO::Handle;
use strict;
use warnings;
$| = 1;

our $VERSION = '0.20';
use base 'Exporter';

our @EXPORT = qw(fork wait waitall waitpid);
my @export_ok_func = qw(isValidPid pause Time read_stdout read_stderr
			bg_eval bg_qx);
my @export_ok_vars = qw(%CHILD_STDOUT %CHILD_STDERR %CHILD_STDIN);
our @EXPORT_OK = (@export_ok_func, @export_ok_vars);
our %EXPORT_TAGS = ( 'test' =>  [ 'isValidPid', 'Time', 'bg_eval' ],
		     'test_config' => [ 'isValidPid', 'Time', 'bg_eval' ],
		     'filehandles' => [ @export_ok_vars ],
		     'all' => [ @export_ok_func ] );
our ($SIG_DEBUG, @CHLD_HANDLE_HISTORY, @SIGCHLD_CAUGHT) = (0);
our ($MAIN_PID, $ON_BUSY, $MAX_PROC, $MAX_LOAD);
our ($DONT_CLEANUP, $CHILD_FORK_OK, $QUEUE_INTERRUPT, $PKG_INITIALIZED);
our (%BASTARD_DATA);
our $SOCKET_READ_TIMEOUT = 1.0;

sub _init {
  return if $PKG_INITIALIZED;
  $PKG_INITIALIZED++;
  $MAIN_PID = $$;

  Forks::Super::Debug::init();
  Forks::Super::Config::init();

  $MAX_PROC = 0;
  $MAX_LOAD = 0;
  $CHILD_FORK_OK = 0;
  $DONT_CLEANUP = 0;

  $Forks::Super::Util::DEFAULT_PAUSE = 0.25;
  if ($^O eq "MSWin32") {
    Forks::Super::Util::set_productive_pause_code { 
      Forks::Super::handle_CHLD(-1);
      Forks::Super::Queue::run_queue();
    };
  } else {
    Forks::Super::Util::set_productive_pause_code { 
      Forks::Super::Queue::run_queue();
    };
  }

  Forks::Super::Wait::set_productive_waitpid_code {
    if ($^O eq "MSWin32") {
      Forks::Super::handle_CHLD(-1);
    }
  };

  tie $ON_BUSY, 'Tie::Enum', qw(block fail queue);
  $ON_BUSY = 'block';

  Forks::Super::Queue::init();

  $SIG{CHLD} = \&Forks::Super::handle_CHLD;
  return;
}

sub import {
  my ($class,@args) = @_;
  my @tags;
  _init();
  for (my $i=0; $i<@args; $i++) {
    if ($args[$i] eq "MAX_PROC") {
      $MAX_PROC = $args[++$i];
    } elsif ($args[$i] eq "MAX_LOAD") {
      $MAX_LOAD = $args[++$i];
    } elsif ($args[$i] eq "DEBUG") {
      $DEBUG = $args[++$i];
    } elsif ($args[$i] eq "ON_BUSY") {
      $ON_BUSY = $args[++$i];
    } elsif ($args[$i] eq "CHILD_FORK_OK") {
      $CHILD_FORK_OK = $args[++$i];
    } elsif ($args[$i] eq "QUEUE_MONITOR_FREQ") {
      $Forks::Super::Queue::QUEUE_MONITOR_FREQ = $args[++$i];
    } elsif ($args[$i] eq "QUEUE_INTERRUPT") {
      $QUEUE_INTERRUPT = $args[++$i];
    } elsif ($args[$i] eq "FH_DIR") {
      my $dir = $args[++$i];
      if ($dir =~ /\S/ && -d $dir && -r $dir && -w $dir && -x $dir) {
	Forks::Super::Job::Ipc::_set_fh_dir($dir);
      } else {
	carp "Forks::Super: Invalid FH_DIR value \"$dir\": $!\n";
      }
    } else {
      push @tags, $args[$i];
      if ($args[$i] =~ /^:test/) {
	no warnings;
	*Forks::Super::Job::carp = *Forks::Super::carp
	  = *Tie::Enum::carp = sub { warn @_ };
	*Forks::Super::Job::croak = *Forks::Super::croak = sub { die @_ };
	$Forks::Super::Config::IS_TEST = 1;
	$Forks::Super::Config::IS_TEST_CONFIG = 1 if $args[$i] =~ /config/;
      }
    }
  }

  $Forks::Super::IMPORT{$_}++ foreach @tags;
  Forks::Super->export_to_level(1, "Forks::Super", @tags, @EXPORT);
  return;
}

################# to export ###################


sub fork {
  my ($opts) = @_;
  if (ref $opts ne 'HASH') {
    $opts = { @_ };
  }

  my $job = Forks::Super::Job->new($opts);
  $job->preconfig;
  if (defined $job->{__test}) {
    return $job->{__test};
  }

  debug('fork(): ', $job->toString(), ' initialized.') if $job->{debug};

  until ($job->can_launch) {

    debug("fork(): job can not launch. Behavior=$job->{_on_busy}")
      if $job->{debug};

    if ($job->{_on_busy} eq "FAIL") {
      $job->run_callback("fail");
      return -1;
    } elsif ($job->{_on_busy} eq "QUEUE") {
      $job->run_callback("queue");
      # Forks::Super::Queue::queue_job($job);
      $job->queue_job;
      return $job->{pid};
    } else {
      pause();
    }
  }

  debug('Forks::Super::fork(): launch approved for job')
    if $job->{debug};
  return $job->launch;
}


#
# called from a child process immediately after it
# is created. Erases all the global state that only needs
# to be available to the parent.
#
sub init_child {
  if ($$ == $MAIN_PID) {
    carp "Forks::Super::init_child() method called from main process!\n";
    return;
  }
  Forks::Super::Queue::init_child();

  @ALL_JOBS = ();
  $SIG{CHLD} = $SIG{CLD} = 'DEFAULT';

  Forks::Super::Config::init_child();
  Forks::Super::Job::init_child();
  return;
}

#
# default SIGCHLD handler to reap completed child
# processes.
#
# may also be invoked synchronously with argument -1
# if we are worried that some previous CHLD signals
# were not handled correctly.
#
sub handle_CHLD {
  # so far I have never observed this local function getting called.
  local $SIG{CHLD} = sub {
    $SIGCHLD_CAUGHT[0]++;
    $SIGCHLD_CAUGHT[1]++;
    debug("Forks::Super::handle_CHLD[2]: SIGCHLD caught local")
      if $DEBUG;
  } if $^O ne "MSWin32";
  $SIGCHLD_CAUGHT[0]++;
  if ($SIG_DEBUG) {
    push @CHLD_HANDLE_HISTORY, "start\n";
  }
  my $sig = shift;
  if ($sig ne "-1" && $DEBUG) {
    debug("Forks::Super::handle_CHLD(): $sig received");
  }

  my $nhandled = 0;

  for (;;) {
    my $pid = -1;
    my $old_status = $?;
    my $status = $old_status;
    for (my $tries=1; !isValidPid($pid) && $tries <= 10; $tries++) {
      $pid = CORE::waitpid -1, WNOHANG;
      $status = $?;
    }
    $? = $old_status;
    last if !isValidPid($pid);

    $nhandled++;

    if (defined $ALL_JOBS{$pid}) {
      debug("Forks::Super::handle_CHLD(): ",
	    "preliminary reap for $pid status=$status") if $DEBUG;
      push @CHLD_HANDLE_HISTORY, "reap $pid $status\n"
	if $SIG_DEBUG;

      my $j = $ALL_JOBS{$pid};
      $j->{status} = $status;
      $j->mark_complete;
    } else {
      # There are (at least) two reasons that we get to this code branch:
      #
      # 1. A child process completes so quickly that it is reaped in this subroutine
      #    before the parent process has finished initializing its state.
      #    Treat this as a bastard pid. We'll check later if the parent process
      #    knows about this process.
      # 2. In Cygwin, the system sometimes fails to clean up the process
      #    correctly. I notice this mainly with deferred jobs.
      debug("Forks::Super::handle_CHLD(): got CHLD signal ",
	    "but can't find child to reap; pid=$pid") if $DEBUG;

      $BASTARD_DATA{$pid} = [ Forks::Super::Time(), $status ];
    }
  }
  Forks::Super::Queue::run_queue() if $nhandled > 0;
  if ($SIG_DEBUG) {
    push @CHLD_HANDLE_HISTORY, "end\n";
  }
  return;
}


#
# returns the exit status of the given process ID or job ID.
# return undef if we don't think the process is complete yet.
#
sub status {
  my $job = shift;
  if (ref $job ne 'Forks::Super::Job') {
    $job = Forks::Super::Job::get($job) || return;
  }
  return $job->{status}; # might be undef
}

sub state {
  my $job = shift;
  if (ref $job ne 'Forks::Super::Job') {
    $job = Forks::Super::Job::get($job) || return;
  }
  return $job->{state};
}

sub write_stdin {
  my ($job, @msg) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $ALL_JOBS{$job} || return;
  }
  my $fh = $job->{child_stdin};
  if (defined $fh) {
    return print $fh @msg;
  } else {
    carp "Forks::Super::write_stdin(): ",
      "Attempted write on child $job->{pid} with no STDIN filehandle\n";
  }
  return;
}

sub _read_socket {
  my ($job, $sh, $wantarray) = @_;

  if (!defined $sh) {
    carp "Forks::Super::_read_socket: ",
      "read on undefined filehandle for ",$job->toString(),"\n";
  }

  if ($sh->blocking() || $^O eq "MSWin32") {
    my $fileno = fileno($sh);
    if (not defined $fileno) {
      $fileno = Forks::Super::Job::Ipc::fileno($sh);
      Carp::cluck "Cannot determine FILENO for socket handle $sh!";
    }

    my ($rin,$rout,$ein,$eout);
    my $timeout = $SOCKET_READ_TIMEOUT || 1.0;
    $rin = '';
    vec($rin, $fileno, 1) = 1;

    # perldoc select: warns against mixing select4 (unbuffered input) with
    # readline (buffered input). Do I have to do my own buffering? That would be weak.

    local $!; undef $!;
    my ($nfound,$timeleft) = select $rout=$rin,undef,undef, $timeout;
    if (!$nfound) {
      if ($DEBUG) {
	debug("no input found on $sh/$fileno");
      }
      return;
    }

    if ($nfound == -1) {
      warn "Forks::Super:_read_socket: ",
	"Error in select4(): $! $^E. \$eout=$eout; \$ein=$ein\n";
    }
  }
  return readline($sh);
}

#
# called from the parent process,
# attempts to read a line from standard output filehandle
# of the specified child.
#
# returns "" if the process is running but there is no
# output waiting on the filehandle
#
# returns undef if the process has completed and there is
# no output waiting on the filehandle
#
# performs trivial seek on filehandle before reading.
# this will reduce performance but will always clear
# error condition and eof condition on handle
#
sub read_stdout {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $ALL_JOBS{$job} || return;
  }
  if ($job->{child_stdout_closed}) {
    if ($job->{debug} && !$job->{_warned_stdout_closed}++) {
      debug("Forks::Super::read_stdout(): ",
	    "fh closed for $job->{pid}");
    }
    return;
  }
  my $fh = $job->{child_stdout};
  if (not defined $fh) {
    if ($job->{debug}) {
      debug("Forks::Super::read_stdout(): ",
	    "fh unavailable for $job->{pid}");
    }
    $job->{child_stdout_closed}++;
    return;
  }
  if (defined getsockname($fh)) {
    return _read_socket($job, $fh, wantarray);
  }

  undef $!;
  if (wantarray) {
    my @lines = readline($fh);
    if (0 == @lines) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  debug("Forks::Super::read_stdout(): ",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stdout_closed}++;
	close $fh;
	return;
      } else {
	@lines = ('');
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return @lines;
  } else {
    my $line = readline($fh);
    if (not defined $line) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  debug("Forks::Super::read_stdout(): :",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stdout_closed}++;
	close $fh;
	return;
      } else {
	$line = '';
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return $line;
  }
}

#
# like read_stdout() but for stderr.
#
sub read_stderr {
  my ($job, $block_NOT_IMPLEMENTED) = @_;
  if (ref $job ne 'Forks::Super::Job') {
    $job = $ALL_JOBS{$job} || return;
  }
  if ($job->{child_stderr_closed}) {
    if ($job->{debug} && !$job->{_warned_stderr_closed}++) {
      debug("Forks::Super::read_stderr(): ",
	    "fh closed for $job->{pid}");
    }
    return;
  }
  my $fh = $job->{child_stderr};
  if (not defined $fh) {
    if ($job->{debug}) {
      debug("Forks::Super::read_stderr(): ",
	    "fh unavailable for $job->{pid}");
    }
    $job->{child_stderr_closed}++;
    return;
  }
  if (defined getsockname($fh)) {
    return _read_socket($job, $fh, wantarray);
  }

  undef $!;
  if (wantarray) {
    my @lines = readline($fh);
    if (0 == @lines) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  debug("Forks::Super::read_stderr(): ",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stderr_closed}++;
	close $fh;
	return;
      } else {
	@lines = ('');
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return @lines;
  } else {
    my $line = readline($fh);
    if (not defined $line) {
      if ($job->is_complete && Forks::Super::Time() - $job->{end} > 3) {
	if ($job->{debug}) {
	  debug("Forks::Super::read_stderr(): ",
		"child $job->{pid} is complete. Closing $fh");
	}
	$job->{child_stderr_closed}++;
	close $fh;
	return;
      } else {
	$line = '';
	seek $fh, 0, 1;
	Forks::Super::pause();
      }
    }
    return $line;
  }
}

##################################################

# use Forks::Super::LazyEval;
######################################################################
# ================================================================== #
# future Forks::Super::LazyEval package

# package Forks::Super::LazyEval
# use Exporter; use base 'Exporter';
# use Carp; use strict; use warnings;
# our @EXPORT = qw(bg_eval bg_qx);

sub bg_eval (&;@) {
  require YAML;
  my ($code, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq "HASH") {
    @other_options = %{$other_options[0]};
  }
  my $p = $$;
  my ($result, @result);
  if (wantarray) {
    tie @result, 'Forks::Super::BackgroundTieArray', $code, @other_options;
    return @result;
  } else {
    tie $result, 'Forks::Super::BackgroundTieScalar', $code, @other_options;
    if ($$ != $p) {
      # a WTF observed on MSWin32
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return \$result;
  }
}

sub Forks::Super::BackgroundTieScalar::TIESCALAR {
  my ($class, $code, %other_options) = @_;
  my $self = { code => $code, value_set => 0 };
  $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
			  sub => sub {
			    my $Result = $code->();
			    print STDOUT YAML::Dump($Result);
			  } };
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  $self->{value} = undef;
  bless $self, $class;
  return $self;
}

sub Forks::Super::BackgroundTieScalar::_retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, 0;
    if ($pid != $self->{job}->{real_pid}) {
      carp "Forks::Super::bg_eval: failed to retrieve result from process!\n";
      $self->{value_set} = 1;
      return;
    }
  }
  my ($result) = YAML::Load( join'', Forks::Super::read_stdout($self->{job_id}) );
  $self->{value_set} = 1;
  return $self->{value} = $result;
}

sub Forks::Super::BackgroundTieScalar::FETCH {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return $self->{value};
}

sub Forks::Super::BackgroundTieScalar::STORE {
  my ($self, $new_value) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $old_value = $self->{value};
  $self->{value} = $new_value;
  return $old_value;
}

sub Forks::Super::BackgroundTieArray::TIEARRAY {
  my ($classname, $code, %other_options) = @_;
  my $self = { code => $code, value_set => 0, value => undef };
  $self->{job_id} = Forks::Super::fork { %other_options, child_fh => "out",
	  sub => sub {
	    my @Result = $code->();
	    print STDOUT YAML::Dump(@Result);
	  } };
  $self->{job} = Forks::Super::Job::get($self->{job_id});
  bless $self, $classname;
  return $self;
}

sub Forks::Super::BackgroundTieArray::_retrieve_value {
  my $self = shift;
  if (!$self->{job}->is_complete) {
    my $pid = Forks::Super::waitpid $self->{job_id}, 0;
    if ($pid != $self->{job}->{real_pid}) {
      carp "Forks::Super::bg_eval: failed to retrieve result from process\n";
      $self->{value_set} = 1;
      return;
    }
  }
  my @result = YAML::Load( join'', Forks::Super::read_stdout($self->{job_id}) );
  $self->{value} = [ @result ];
  $self->{value_set} = 1;
  return;
}

sub Forks::Super::BackgroundTieArray::FETCH {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return $self->{value}->[$index];
}

sub Forks::Super::BackgroundTieArray::STORE {
  my ($self, $index, $new_value) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $old_value = $self->{value}->[$index];
  $self->{value}->[$index] = $new_value;
  return $old_value;
}

sub Forks::Super::BackgroundTieArray::FETCHSIZE {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return scalar @{$self->{value}};
}

sub Forks::Super::BackgroundTieArray::STORESIZE {
  my ($self, $count) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  my $diff = $count - $self->FETCHSIZE();
  if ($diff > 0) {
    push @{$self->{value}}, (undef) x $diff;
  } else {
    splice @{$self->{value}}, $diff;
  }
}

sub Forks::Super::BackgroundTieArray::DELETE {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return delete $self->{value}->[$index];
}

sub Forks::Super::BackgroundTieArray::CLEAR {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  $self->{value} = [];
}

sub Forks::Super::BackgroundTieArray::PUSH {
  my ($self, @list) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  push @{$self->{value}}, @list;
  return $self->FETCHSIZE();
}

sub Forks::Super::BackgroundTieArray::UNSHIFT {
  my ($self, @list) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  unshift @{$self->{value}}, @list;
  return $self->FETCHSIZE();
}

sub Forks::Super::BackgroundTieArray::POP {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return pop @{$self->{value}};
}

sub Forks::Super::BackgroundTieArray::SHIFT {
  my $self = shift;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return shift @{$self->{value}};
}

sub Forks::Super::BackgroundTieArray::SPLICE {
  my ($self, $offset, $length, @list) = @_;
  $offset = 0 if !defined $offset;
  $length = $self->FETCHSIZE() - $offset if !defined $length;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return splice @{$self->{value}}, $offset, $length, @list;
}

sub Forks::Super::BackgroundTieArray::EXISTS {
  my ($self, $index) = @_;
  if (!$self->{value_set}) {
    $self->_retrieve_value;
  }
  return exists $self->{value}->[$index];
}
1;
# ================================================================== #
######################################################################


1;

__END__

------------------------------------------------------------------------------

=head1 NAME

Forks::Super - extensions and convenience methods for managing background processes.

=head1 VERSION

Version 0.20

=head1 SYNOPSIS

    use Forks::Super;
    use Forks::Super MAX_PROC => 5, DEBUG => 1;

    # familiar use - parent returns PID>0, child returns zero
    $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid > 0) {
        # parent code
    } else {
        # child code
    }

    # wait for a child process to finish
    $w = wait;                  # blocking wait on any child, $? holds child exit status
    $w = waitpid $pid, 0;       # blocking wait on specific child
    $w = waitpid $pid, WNOHANG; # non-blocking wait, use with POSIX ':sys_wait_h'
    $w = waitpid 0, $flag;      # wait on any process in current process group
    waitall;                    # block until all children are finished

    # -------------- helpful extensions ---------------------
    # fork directly to a shell command. Child doesn't return.
    $pid = fork { cmd => "./myScript 17 24 $n" };
    $pid = fork { exec => [ "/bin/prog" , $file, "-x", 13 ] };

    # fork directly to a Perl subroutine. Child doesn't return.
    $pid = fork { sub => $methodNameOrRef , args => [ @methodArguments ] };
    $pid = fork { sub => \&subroutine, args => [ @args ] };
    $pid = fork { sub => sub { "anonymous sub" }, args => [ @args ] );

    # put a time limit on the child process
    $pid = fork { cmd => $command, timeout => 30 };            # kill child if not done in 30s
    $pid = fork { sub => $subRef , expiration => 1260000000 }; # complete by 8AM Dec 5, 2009 UTC

    # obtain standard filehandles for the child process
    $pid = fork { child_fh => "in,out,err" };
    if ($pid == 0) {      # child process
      sleep 1;
      $x = <STDIN>; # read from parent's $Forks::Super::CHILD_STDIN{$pid}
      print rand() > 0.5 ? "Yes\n" : "No\n" if $x eq "Clean your room\n";
      sleep 2;
      $i_can_haz_ice_cream = <STDIN>;
      if ($i_can_haz_ice_cream !~ /you can have ice cream/ && rand() < 0.5) {
          print STDERR '@#$&#$*&#$*&',"\n";
      }
      exit 0;
    } # else parent process
    $child_stdin = $Forks::Super::CHILD_STDIN{$pid};
    print $child_stdin "Clean your room\n";
    sleep 2;
    $child_stdout = $Forks::Super::CHILD_STDOUT{$pid};
    $child_response = <$child_stdout>; # -or-  = Forks::Super::read_stdout($pid);
    if ($child_response eq "Yes\n") {
        print $child_stdin "Good boy. You can have ice cream.\n";
    } else {
        print $child_stdin "Bad boy. No ice cream for you.\n";
        sleep 2;
        $child_err = Forks::Super::read_stderr($pid);
        # -or-  $child_err = readline($Forks::Super::CHILD_STDERR{$pid});
        print $child_stdin "And no back talking!\n" if $child_err;
    }

    # ---------- manage jobs and system resources ---------------
    # runs 100 tasks but the fork call blocks when there are already 5 jobs running
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'block';
    for ($i=0; $i<100; $i++) {
      $pid = fork { cmd => $task[$i] };
    }

    # jobs fail (without blocking) if the system is too busy
    $Forks::Super::MAX_PROC = 5;
    $Forks::Super::ON_BUSY = 'fail';
    $pid = fork { cmd => $task };
    if    ($pid > 0) { print "'$task' is running\n" }
    elsif ($pid < 0) { print "5 or more jobs running -- didn't start '$task'\n"; }

    # $Forks::Super::MAX_PROC setting can be overridden. Start job immediately if < 3 jobs running
    $pid = fork { sub => 'MyModule::MyMethod', args => [ @b ], max_proc => 3 };

    # try to fork no matter how busy the system is
    $pid = fork { force => 1, sub => \&MyMethod, args => [ @my_args ] };

    # when system is busy, queue jobs. When system is not busy, some jobs on the queue will start.
    # if job is queued, return value from fork() is a very negative number
    $Forks::Super::ON_BUSY = 'queue';
    $pid = fork { cmd => $command };
    $pid = fork { cmd => $useless_command, queue_priority => -5 };
    $pid = fork { cmd => $important_command, queue_priority => 5 };
    $pid = fork { cmd => $future_job, delay => 20 }   # keep job on queue for at least 20s

    # assign descriptive names to tasks
    $pid1 = fork { cmd => $command, name => "my task" };
    $pid2 = waitpid "my task", 0;

    # run callbacks at various points of job life-cycle
    $pid = fork { cmd => $command, callback => \&on_complete };
    $pid = fork { sub => $sub, callback => { start => 'on_start', finish => \&on_complete,
                                             queue => sub { print "Job $_[1] queued.\n" } } };

    # set up dependency relationships
    $pid1 = fork { cmd => $job1 };
    $pid2 = fork { cmd => $job2, depend_on => $pid1 };            # put on queue until job 1 is complete
    $pid4 = fork { cmd => $job4, depend_start => [$pid2,$pid3] }; # put on queue until jobs 2,3 have started

    $pid5 = fork { cmd => $job5, name => "group C" };
    $pid6 = fork { cmd => $job6, name => "group C" };
    $pid7 = fork { cmd => $job7, depend_on => "group C" }; # wait for jobs 5 & 6 to complete

    # manage OS settings on jobs -- not available on all systems
    $pid1 = fork { os_priority => 10 };    # like nice(1) on Un*x
    $pid2 = fork { cpu_affinity => 0x5 };  # background task will prefer CPUs #0 and #2

    # job information
    $state = Forks::Super::state($pid);    # 'ACTIVE', 'DEFERRED', 'COMPLETE', 'REAPED'
    $status = Forks::Super::status($pid);  # exit status for completed jobs

    # --- evaluate long running expressions in the background
    $result = bg_eval { a_long_running_calculation() };
    # sometime later ...
    print "Result was $$result\n";

=head1 DESCRIPTION

This package provides new definitions for the Perl functions
C<fork>, C<wait>, and C<waitpid> with richer functionality.
The new features are designed to make it more convenient to
spawn background processes and more convenient to manage them
and to get the most out of your system's resources.

=head1 C<$pid = fork( \%options )>

The new C<fork> call attempts to spawn a new process.
With no arguments, it behaves the same as the Perl system
call L<< C<fork()>|perlfunc/fork >>:

=over 4

=item * 

creating a new process running the same program at the same point

=item * 

returning the process id (PID) of the child process to the parent.

On Windows, this is a I<pseudo-process ID> 

=item * 

returning 0 to the child process

=item * 

returning C<undef> if the fork call was unsuccessful

=back

=head2 Options for instructing the child process

The C<fork> call supports three options, C<cmd>, C<exec>,
and C<sub> (or C<sub>/C<args>)
that will instruct the child process to carry out a specific task. Using 
either of these options causes the child process not to return from the 
C<fork> call.

=over 4

=item C<< $child_pid = fork { cmd => $shell_command } >>

=item C<< $child_pid = fork { cmd => \@shell_command } >>

On successful launch of the child process, runs the specified shell command
in the child process with the Perl C<system()> function. When the system
call is complete, the child process exits with the same exit status that
was returned by the system call. 

Returns the PID of the child process to
the parent process. Does not return from the child process, so you do not
need to check the fork() return value to determine whether code is
executing in the parent or child process.

=back

=over 4

=item C<< $child_pid = fork { exec => $shell_command } >>

=item C<< $child_pid = fork { exec => \@shell_command } >>

Like the C<cmd> option, but the background process launches the
shell command with C<exec> instead of with C<system>.

Using C<exec> instead of C<cmd> will spawn one fewer process,
but note that the C<timeout> and C<expiration> options cannot
be used with the C<exec> option (see 
L<"Options for simple job management">).

=back

=over 4

=item C<< $child_pid = fork { sub => $subroutineName [, args => \@args ] } >>

=item C<< $child_pid = fork { sub => \&subroutineReference [, args => \@args ] } >>

=item C<< $child_pid = fork { sub => sub { ... code ... } [, args => \@args ] } >>

On successful launch of the child process, C<fork> invokes the specified
Perl subroutine with the specified set of method arguments (if provided).
If the subroutine completes normally, the child process exits with
a status of zero. If the subroutine exits abnormally (i.e., if it
C<die>s, or if the subroutine invokes C<exit> with a non-zero
argument), the child process exits with non-zero status. 

Returns the PID of the child process to the parent process.
Does not return from the child process, so you do not need to check the
fork() return value to determine whether code is running in the parent or
child process.

If neither the C<cmd> or the C<sub> option is provided to the fork call,
then the fork() call behaves like a Perl C<fork()> call, returning 
the child PID to the parent and also returning zero to the child.

=back

=head2 Options for simple job management

=over 4

=item C<< fork { timeout => $delay_in_seconds } >>

=item C<< fork { expiration => $timestamp_in_seconds_since_epoch_time } >>

Puts a deadline on the child process and causes the child to C<die> 
if it has not completed by the deadline. With the C<timeout> option,
you specify that the child process should not survive longer than the
specified number of seconds. With C<expiration>, you are specifying
an epoch time (like the one returned by the C<time> function) as the
child process's deadline.

If the C<setpgrp()> system call is implemented on your system,
then this module will try to reset the process group ID of the child 
process. On timeout, the module will attempt to kill off all
subprocesses of the expiring child process.

If the deadline is some time in the past (if the timeout is
not positive, or the expiration is earlier than the current time),
then the child process will die immediately after it is created.

Note that this feature uses the Perl C<alarm> call with a
handler for C<SIGALRM>. If you use this feature and also specify a
C<sub> to invoke, and that subroutine also tries to use the
C<alarm> feature or set a handler for C<SIGALRM>, the results 
will be undefined.

The C<timeout> and C<expiration> options cannot be used with the
C<exec> option, since the child process will not be able to
generate a C<SIGALRM> after an C<exec> call.

=item C<< fork { delay => $delay_in_seconds } >>

=item C<< fork { start_after => $timestamp_in_epoch_time } >>

Causes the child process to be spawned at some time in the future. 
The return value from a C<fork> call that uses these features
will not be a process id, but it will be a very negative number
called a job ID. See the section on L</"Deferred processes">
for information on what to do with a job ID.

A deferred job will start B<no earlier> than its appointed time
in the future. Depending on what circumstances the queued jobs
are examined, the actual start time of the job could be significantly
later than the appointed time.

A job may have both a minimum start time (through C<delay> or
C<start_after> options) and a maximum end time (through
C<timeout> and C<expiration>). Jobs with inconsistent times
(end time is not later than start time) will be killed of
as soon as they are created.

=item C<< fork { child_fh => $fh_spec } >>

=item C<< fork { child_fh => [ @fh_spec ] } >>

B<Note: API change since v0.10.>

Launches a child process and makes the child process's 
STDIN, STDOUT, and/or STDERR filehandles available to
the parent process in the scalar variables
$Forks::Super::CHILD_STDIN{$pid}, $Forks::Super::CHILD_STDOUT{$pid},
and/or $Forks::Super::CHILD_STDERR{$pid}, where $pid is the PID
return value from the fork call. This feature makes it possible,
even convenient, for a parent process to communicate with a
child, as this contrived example shows.

    $pid = fork { sub => \&pig_latinize, timeout => 10,
                  child_fh => "all" };

    # in the parent, $Forks::Super::CHILD_STDIN{$pid} is an *output* filehandle
    print {$Forks::Super::CHILD_STDIN{$pid}} "The blue jay flew away in May\n";

    sleep 2; # give child time to start up and get ready for input

    # and $Forks::Super::CHILD_STDOUT{$pid} is an *input* handle
    $result = <{$Forks::Super::CHILD_STDOUT{$pid}}>;
    print "Pig Latin translator says: $result\n"; # ==> eThay ueblay ayjay ewflay awayay inay ayMay\n
    @errors = <{$Forks::Super::CHILD_STDERR{$pid}>;
    print "Pig Latin translator complains: @errors\n" if @errors > 0;

    sub pig_latinize {
      for (;;) {
        while (<STDIN>) {
	  foreach my $word (split /\s+/) {
            if ($word =~ /^qu/i) {
              print substr($word,2) . substr($word,0,2) . "ay";  # STDOUT
            } elsif ($word =~ /^([b-df-hj-np-tv-z][b-df-hj-np-tv-xz]*)/i) {
              my $prefix = 1;
              $word =~ s/[b-df-hj-np-tv-z][b-df-hj-np-tv-xz]*//i;
	      print $word . $prefix . "ay";
	    } elsif ($word =~ /^[aeiou]/i) {
              print $word . "ay";
            } else {
	      print STDERR "Didn't recognize this word: $word\n";
            }
            print " ";
          }
	  print "\n";
        }
      }
    }

The set of filehandles to make available are specified either as
a non-alphanumeric delimited string, or list reference. This spec
may contain one or more of the words C<in>, C<out>, C<err>,
C<join>, C<all>, or C<socket>. 

C<in>, C<out>, and C<err> mean that the child's STDIN, STDOUT,
and STDERR, respectively, will be available in the parent process
through the filehandles in C<$Forks::Super::CHILD_STDIN{$pid}>,
C<$Forks::Super::CHILD_STDOUT{$pid}>, 
and C<$Forks::Super::CHILD_STDERR{$pid}>, where C<$pid> is the
child's process ID. C<all> is a convenient way to specify
C<in>, C<out>, and C<err>. C<join> specifies that the child's
STDOUT and STDERR will be returned through the same filehandle,
specified as both C<$Forks::Super::CHILD_STDOUT{$pid}> and
C<$Forks::Super::CHILD_STDERR{$pid}>.

If C<socket> is specified, then local sockets will be used to
pass between parent and child instead of temporary files.

=back

=head3 Socket handles vs. file handles

Here are some things to keep in mind when deciding whether to
use sockets or regular files for parent-child IPC:

=over 4

=item * 

Sockets have a performance advantage, especially at 
child process start-up.

=item * 

Socket input buffers have limited capacity. Write operations 
can block if the socket reader is not vigilant

=item * 

On Windows, sockets are blocking, and care must be taken
to prevent your script from reading on an empty socket

=back

=cut 

It is an open question (that is to say: I personally haven't researched it)
whether opening socket handles counts against your program's limit
of simultaneous open filehandles.

=head3 Socket and file handle gotchas

Some things to keep in mind when using socket or file handles
to communicate with a child process.

=over 4

=item * 

care should be taken before C<close>'ing a socket handle.
The same socket handle can be used for both reading and writing.
Don't close a handle when you are only done with one half of the
socket operations.

=item * 

The test C<defined getsockname($handle)> can determine
whether C<$handle> is a socket handle or a regular filehandle.

=item * 

The following idiom is safe to use on both socket handles
and regular filehandles:

    shutdown($handle,2) || close $handle;

=item * 

IPC in this module is asynchronous. In general, you
cannot tell whether the parent/child has written anything to
be read in the child/parent. So getting C<undef> when reading
from the C<$Forks::Super::CHILD_STDOUT{$pid}> handle does not
necessarily mean that the child has finished (or even started!)
writing to its STDOUT. Check out the C<seek HANDLE,0,1> trick
in L<the perlfunc documentation for seek|perlfunc/seek> 
about reading from a handle after you have
already read past the end. You may find it useful for your
parent and child processes to follow some convention (for example,
a special word like C<"__END__">) to denote the end of input.

=item C<< fork { stdin => $input } >>

Provides the data in C<$input> as the child process's standard input.
Equivalent, but a little more efficient than:

    $pid = fork { child_fh => "in", sub => sub { ... } };
    print {$Forks::Super::CHILD_STDIN{$pid}} $input;

C<$input> may either be a scalar, a reference to a scalar, or
a reference to an array.

=item C<< fork { stdout => \$output } >>

=item C<< fork { stderr => \$errput } >>

On completion of the background process, loads the standard output
and standard error of the child process into the given scalar 
references. If you do not need to use the child's output while
the child is running, it could be more convenient to use this
construction than calling C<Forks::Super::read_stdout($pid)>
(or C<< <{$Forks::Super::CHILD_STDOUT{$pid}}> >>) to obtain
the child's output.

=back

=head2 Options for complicated job management

The C<fork()> call from this module supports options that help to
manage child processes or groups of child processes in ways to better
manage your system's resources. For example, you may have a lot of tasks
to perform in the background, but you don't want to overwhelm your 
(possibly shared) system by running them all at once. There are features
to control how many, how, and when your jobs will run.

=over 4

=item C<< fork { name => $name } >>

Attaches a string identifier to the job. The identifier can be used
for several purposes:

=over 4

=item * to obtain a L<Forks::Super::Job> object representing the
background task through the C<Forks::Super::Job::get> or
C<Forks::Super::Job::getByName> methods.

=item * as the first argument to C<waitpid> to wait on a job or jobs
with specific names

=item * to identify and establish dependencies between background tasks.
See the C<depend_on> and C<depend_start> parameters below.

=item * if supported by your system, the name attribute will change
the argument area used by the ps(1) program and change the 
way the background process is displaying in your process viewer.
(See L<$PROGRAM_NAME in perlvar|perlvar/"$PROGRAM_NAME"> 
about overriding the special C<$0> variable.)

=back

=item C<$Forks::Super::MAX_PROC = $max_simultaneous_jobs>

=item C<< fork { max_fork => $max_simultaneous_jobs } >>

Specifies the maximum number of background processes that you want to run.
If a C<fork> call is attempted while there are already the maximum
number of child processes running, then the C<fork()> call will either
block (until some child processes complete), fail (return a negative
value without spawning the child process), or queue the job (returning
a very negative value called a job ID), according to the specified
"on_busy" behavior (see the next item). See the L</"Deferred processes">
section for information about how queued jobs are handled.

On any individual C<fork> call, the maximum number of processes may be
overridden by also specifying C<max_proc> or C<force> options. 

    $Forks::Super::MAX_PROC = 8;
    # launch 2nd job only when system is very not busy
    $pid1 = fork { sub => 'method1' };
    $pid2 = fork { sub => 'method2', max_proc => 1 };
    $pid3 = fork { sub => 'method3' };

Setting $Forks::Super::MAX_PROC to zero or a negative number will disable the
check for too many simultaneous processes.

=item C<$Forks::Super::ON_BUSY = "block" | "fail" | "queue">

=item C<< fork { on_busy => "block" | "fail" | "queue" } >>

Dictates the behavior of C<fork> in the event that the module is not allowed
to launch the specified job for whatever reason.

=over 4

=item C<"block">

If the system cannot create a new child process for the specified job,
it will wait and periodically retry to create the child process until
it is successful. Unless a system fork call is attempted and fails,
C<fork> calls that use this behavior will return a positive PID.

=item C<"fail">

If the system cannot create a new child process for the specified job,
the C<fork> call will immediately return with a small negative
value.

=item C<"queue">

If the system cannot create a new child process for the specified job,
the job will be deferred, and an attempt will be made to launch the
job at a later time. See L</"Deferred processes"> below. The return 
value will be a very negative number (job ID).

=back

On any individual C<fork> call, the default launch failure behavior specified
by $Forks::Super::ON_BUSY can be overridden by specifying a C<on_busy> option:

    $Forks::Super::ON_BUSY = "fail";
    $pid1 = fork { sub => 'myMethod' };
    $pid2 = fork { sub => 'yourMethod', on_busy => "queue" }

=item C<< fork { force => $bool } >>

If the C<force> option is set, the C<fork> call will disregard the
usual criteria for deciding whether a job can spawn a child process,
and will always attempt to create the child process.

=item C<< fork { queue_priority => $priority } >>

In the event that a job cannot immediately create a child process and
is put on the job queue (see L</"Deferred processes">), the C{queue_priority}
specifies the relative priority of the job on the job queue. In general,
eligible jobs with high priority values will be started before jobs
with lower priority values.

=item C<< fork { depend_on => $id } >>

=item C<< fork { depend_on => [ $id_1, $id_2, ... ] } >>

=item C<< fork { depend_start => $id } >>

=item C<< fork { depend_start => [ $id_1, $id_2, ... ] } >>

Indicates a dependency relationship between the job in this C<fork>
call and one or more other jobs. The identifiers may be 
process/job IDs or C<name> attributes (ses above) from
earlier C<fork> calls.

If a C<fork> call specifies a
C<depend_on> option, then that job will be deferred until
all of the child processes specified by the process or job IDs
have B<completed>. If a C<fork> call specifies a
C<depend_start> option, then that job will be deferred until
all of the child processes specified by the process or job
IDs have B<started>.

Invalid process and job IDs in a C<depend_on> or C<depend_start>
setting will produce a warning message but will not prevent 
a job from starting.

Dependencies are established at the time of the C<fork> call
and can only apply to jobs that are known at run time. So for
example, in this code,

    $job1 = fork { cmd => $cmd, name => "job1", depend_on => "job2" };
    $job2 = fork { cmd => $cmd, name => "job2", depend_on => "job1" };

at the time the first job is cereated, the job named "job2" has not
been created yet, so the first job will not have a dependency (and a
warning will be issued when the job is created). This may
be a limitation but it also guarantees that there will be no
circular dependencies.

When a dependency identifier is a name attribute that applies to multiple
jobs, the job will be dependent on B<all> existing jobs with that name:

    # Job 3 will not start until BOTH job 1 and job 2 are done
    $job1 = fork { name => "Sally", ... };
    $job2 = fork { name => "Sally", ... };
    $job3 = fork { depend_on => "Sally", ... };

    # all of these jobs have the same name and depend on ALL previous jobs
    $job4 = fork { name => "Ralph", depend_start => "Ralph", ... }; # no dependencies
    $job5 = fork { name => "Ralph", depend_start => "Ralph", ... }; # depends on Job 4
    $job6 = fork { name => "Ralph", depend_start => "Ralph", ... }; # depends on #4 and #5

=item C<< fork { can_launch => \&methodName } >>

=item C<< fork { can_launch => sub { ... anonymous sub ... } } >>

Supply a user-specified function to determine when a job is
eligible to be started. The function supplied should return
0 if a job is not eligible to start and non-zero if it is
eligible to start. 

During a C<fork> call or when the job queue is being examined,
the user's C<can_launch> method will be invoked with a single
C<Forks::Super::Job> argument containing information about the job
to be launched. User code may make use of the default launch
determination method by invoking the C<_can_launch> method
of the job object:

    # Running on a BSD system with the uptime(1) call.
    # Want to block jobs when the current CPU load 
    # (1 minute) is greater than 4 and respect all other criteria:
    fork { cmd => $my_command,
           can_launch => sub {
             $job = shift;                    # a Forks::Super::Job object
             return 0 if !$job->_can_launch;  # default
             $cpu_load = (split /\s+/,`uptime`)[-3]; # get 1 minute avg CPU load
             return 0 if $cpu_load > 4.0;     # system too busy. let's wait
             return 1;
           } }

=item C<< fork { callback => $subroutineName } >>

=item C<< fork { callback => sub { BLOCK } } >>

=item C<< fork { callback => { start => ..., finish => ..., queue => ..., fail => ... } } >>

Install callbacks to be run when and if certain events in the life cycle
of a background process occur. The first two forms of this option are equivalent to

    fork { callback => { finish => ... } }

and specify code that will be executed when a background process is complete
and the module has received its C<SIGCHLD> event. A C<start> callback is
executed just after a new process is spawned. A C<queue> callback is run
if the job is deferred for any reason (see L</"Deferred processes">) and
the job is placed onto the job queue for the first time. And the C<fail>
callback is run if the job is not going to be launched (that is, a case 
where the C<fork> call would return C<-1>).

Callbacks are invoked with two arguments when they are triggered:
the C<Forks::Super::Job> object that was created with the original
C<fork> call, and the job's ID (the return value from C<fork>).

You should keep your callback functions short and sweet, like you do
for your signal handlers. Sometimes callbacks are invoked from the
signal handler, and the processing of other signals could be
delayed if the callback functions take too long to run.

=item C<< fork { os_priority => $priority } >>

On supported operating systems, and after the successful creation
of the child process, attempt to set the operating system priority
of the child process.

On unsupported systems, this option is ignored.

=item C<< fork { cpu_affinity => $bitmask } >>

On supported operating systems with multiple cores, 
and after the successful creation of the child process, 
attempt to set the process's CPU affinity.
Each bit of the bitmask represents one processor. Set a bit to 1
to allow the process to use the corresponding processor, and set it to
0 to disallow the corresponding processor. There may be additional
restrictions on the valid range of values imposed by the operating
system.

As of version 0.07, supported systems are Cygwin, Win32, Linux,
and possibly BSD.

=item C<< fork { debug => $bool } >>

=item C<< fork { undebug => $bool } >>

Overrides the value in C<$Forks::Super::DEBUG> (see L</"MODULE VARIABLES">)
for this specific job. If specified, the C<debug> parameter
controls only whether the module will output debugging information related
to the job created by this C<fork> call.

Normally, the debugging settings of the parent, including the job-specific
settings, are inherited by child processes. If the C<undebug> option is
specified with a non-zero parameter value, then debugging will be 
disabled in the child process.

=back

=head2 Deferred processes

Whenever some condition exists that prevents a C<fork()> call from
immediately starting a new child process, an option is to B<defer>
the job. Deferred jobs are placed on a queue. At periodic intervals,
in response to periodic events, or whenever you invoke the
C<Forks::Super::run_queue> method in your code, the queue will be examined
to see if any deferred jobs are eligible to be launched.

=head3 Job ID

When a C<fork()> call fails to spawn a child process but instead
defers the job by adding it to the queue, the C<fork()> call will
return a unique, large negative number called the job ID. The
number will be negative and large enough (E<lt>= -100000) so
that it can be distinguished from any possible PID,
Windows pseudo-process ID, process group ID, or C<fork()>
failure code.

Although the job ID is not the actual ID of a system process, 
it may be used like a PID as an argument to C<waitpid>,
as a dependency specification in another C<fork> call's
C<depend_on> or C<depend_start> option, or
the other module methods used to retrieve job information
(See L</"Obtaining job information"> below). Once a deferred
job has been started, it will be possible to obtain the
actual PID (or on Windows, the actual
psuedo-process ID) of the process running that job.

=head3 Job priority

Every job on the queue will have a priority value. A job's
priority may be set explicitly by including the
C<queue_priority> option in the C<fork()> call, or it will
be assigned a default priority near zero. Every time the
queue is examined, the queue will be sorted by this priority
value and an attempt will be made to launch each job in this
order. Note that different jobs may have different criteria
for being launched, and it is possible that that an eligible
low priority job may be started before an ineligible
higher priority job.

=head3 Queue examination

Certain events in the C<SIGCHLD> handler or in the 
C<wait>, C<waitpid>, and/or C<waitall> methods will cause
the list of deferred jobs to be evaluated and to start
eligible jobs. But this configuration does not guarantee
that the queue will be examined in a timely or frequent
enough basis. The user may invoke the

    Forks::Super::run_queue()

method at any time to cause the queue to be examined.

=head2 Special tips for Windows systems

On POSIX systems (including Cygwin), programs using the
C<Forks> module are interrupted when a child process 
completes. A callback function performs some housekeeping
and may perform other duties like trying to dispatch
things from the list of deferred jobs.

Windows systems do not have the signal handling capabilities
of other systems, and so other things equal, a script
running on Windows will not perform the housekeeping
tasks as frequently as a script on other systems.

The method C<Forks::Super::pause> can be used as a drop in
replacement for the Perl C<sleep> call. In a C<pause>
function call, the program will check on active
child processes, reap the ones that have completed, and
attempt to dispatch jobs on the queue. 

Calling C<pause> with an argument of 0 is also a valid
way of invoking the child handler function on Windows.
When used this way, C<pause> returns immediately after
running the child handler.

Child processes are implemented differently in Windows
than in POSIX systems. The C<CORE::fork> and C<Forks::Super::fork>
calls will usually return a B<pseudo-process ID> to the
parent process, and this will be a B<negative value>. 
The Unix idiom of testing whether a C<fork> call returns
a positive number needs to be modified on Windows systems
by testing whether  C<Forks::Super::isValidPid($pid)> returns
true, where C<$pid> is the return value from a C<Forks::Super::fork>
call.

=head1 OTHER FUNCTIONS

=over 4

=item C<$reaped_pid = wait>

Like the Perl L<< C<wait>|perlfunc/wait >> system call, 
blocks until a child process
terminates and returns the PID of the deceased process,
or C<-1> if there are no child processes remaining to reap.
The exit status of the child is returned in C<$?>.

=cut

XXX - future enhancement: take a timeout argument, in which case
it will not behave exactly like the Perl wait system call.

=item C<$reaped_pid = waitpid $pid, $flags>

Waits for a child with a particular PID or a child from
a particular process group to terminate and returns the
PID of the deceased process, or C<-1> if there is no
suitable child process to reap. If the return value contains
a PID, then C<$?> is set to the exit status of that process.

A valid job ID (see L</"Deferred processes">) may be used
as the $pid argument to this method. If the C<waitpid> call
reaps the process associated with the job ID, the return value
will be the actual PID of the deceased child.

Note that the C<waitpid> function can wait on a
job ID even when the job associated with that ID is
still in the job queue, waiting to be started.

A $pid value of C<-1> waits for the first available child
process to terminate and returns its PID.

A $pid value of C<0> waits for the first available child 
from the same process group of the calling process.

A negative C<$pid> that is not recognized as a valid job ID
will be interpreted as a process group ID, and the C<waitpid>
function will return the PID of the first available child 
from the same process group.

On some^H^H^H^H every modern system that I know about,
 a C<$flags> value of C<POSIX::WNOHANG>
is supported to perform a non-blocking wait. See the
Perl L<< C<waitpid>|perlfunc/waitpid >> documentation.

=cut

XXX - include optional third timeout argument

=item C<waitall>

Blocking wait for all child processes, including deferred
jobs that have not started at the time of the C<waitall>
call.

=item C<Forks::Super::isValidPid( $pid )>

Tests whether the return value of a C<fork> call indicates that
a background process was successfully created or not. On POSIX
systems it is sufficient to check whether C<$pid> is a
positive integer, but C<isValidPid> is a more 

=item C<Forks::Super::pause($delay)>

A B<productive> drop-in replacement for the Perl C<sleep>
system call (or C<Time::HiRes::sleep>, if available). On
systems like Windows that lack a proper method for
handling C<SIGCHLD> events, the C<Forks::Super::pause> method
will occasionally reap child processes that have completed
and attempt to dispatch jobs on the queue. 

On other systems, using C<Forks::Super::pause> is less vulnerable
than C<sleep> to interruptions from this module (See 
L<"BUGS AND LIMITATIONS"> below).

=item C<$status = Forks::Super::status($pid)>

Returns the exit status of a completed child process
represented by process ID or job ID $pid. Aside from being
a permanent store of the exit status of a job, using this
method might be a more reliable indicator of a job's status
than checking C<$?> after a C<wait> or C<waitpid> call. It is
possible for this module's C<SIGCHLD> handler to temporarily
corrupt the C<$?> value while it is checking for deceased
processes.

=item C<$line = Forks::Super::read_stdout($pid)>

=item C<@lines = Forks::Super::read_stdout($pid)>

=item C<$line = Forks::Super::read_stderr($pid)>

=item C<@lines = Forks::Super::read_stderr($pid)>

For jobs that were started with the C<< child_fh => "out" >> and C<< child_fh => "err" >>
options enabled, read data from the STDOUT and STDERR filehandles of child
processes. 

Aside from the more readable syntax, these functions may be preferable to

    @lines = < {$Forks::Super::CHILD_STDOUT{$pid}} >;
    $line = < {$Forks::Super::CHILD_STDERR{$pid}} >;

because they will automatically handle clearing the EOF condition
on the filehandles if the parent is reading on the filehandles faster
than the child is writing on them.

Functions work in both scalar and list context. If there is no data to
read on the filehandle, but the child process is still active and could
put more data on the filehandle, these functions return  ""  in scalar
and list context. If there is no more data on the filehandle and the
child process is finished, the functions return C<undef>.

=back

=head3 Obtaining job information

=over 4

=item C<$job = Forks::Super::Job::get($pid)>

Returns a C<Forks::Super::Job> object associated with process ID or job ID C<$pid>.
See L<Forks::Super::Job> for information about the methods and attributes of
these objects.

=item C<@jobs = Forks::Super::Job::getByName($name)>

Returns zero of more C<Forks::Super::Job> objects with the specified
job names. A job receives a name if a C<name> parameter was provided
in the C<Forks::Super::fork> call.

=item C<< $reference = bg_eval { BLOCK } >>

=item C<< $reference = bg_eval { BLOCK } { option => value, ... } >>

Evaluates the specified block of code in a background process. When the
parent process dereferences the result, it uses interprocess communication
to retrieve the result from the child process, waiting until the child
finishes if necessary.

    # Example 1: must wait until job finishes before $$result is available
    $result = bg_eval { sleep 3 ; return 42 };
    print "Result is $$result\n";

    # Example 2: $$result is probably available immediately
    $result = bg_eval { sleep 3 ; return 42 };
    &do_something_that_takes_about_5_seconds();
    print "Result is $$result\n";

The code block is always evaluated in scalar context, though it is
acceptable to return a reference:

    $result = bg_eval {
            @files = File::Find::find(\&criteria, @lots_of_dirs);
            return \@files;
        };
    # ... do something else while that job runs ...
    foreach my $matching_file (@$$result) { # note double dereference
        # ... do something with $matching_file
    }

The background job will be spawned with the C<Forks::Super::fork> call,
and the command will block, fail, or defer a background job in accordance
with all of the other rules of this module. Additional options may be
passed to C<bg_eval>  that will be provided to the C<fork> call. For
example:

    $result = bg_eval {
            return get_from_teh_Internet($something, $where);
        } { timeout => 60, priority => 3 };

will return a reference to C<undef> if the operation takes longer
than 60 seconds. Most valid options for the C<fork> call are also valid
options for C<bg_eval>, including timeouts, delays, job dependencies,
names, and callback. The only invalid options for C<bg_eval> are
C<cmd>, C<sub>, C<exec>, and C<child_fh>.

=item C<< @result = bg_eval { BLOCK } >>

=item C<< @result = bg_eval { BLOCK } { option => value, ... } >>

Evaluates the specified block of code in a background process and in list
context. The parent process retrieves the result from the child through
interprocess communication the first time that an element of the array
is referenced; the parent will wait for the child to finish if necessary.

The background job will be spawned with the C<Forks::Super::fork>
call, and the command will block, fail, or defer a background job in
accordance with all of the rules of this module. Additional options may
be passed to the C<bg_eval> function that will be provided to the
C<Forks::Super::fork> call. For example:

    @result = bg_eval {
            count_words($a_huge_file)
        } { timeout => 60 };

will return an empty list if the operation takes longer than
60 seconds. Any valid options for the C<fork> call are also valid
options for C<bg_eval>, except for C<exec>, C<cmd>, C<sub>, and
C<child_fh>.

=back

=head1 MODULE VARIABLES

Module variables may be initialized on the C<use Forks::Super> line

    # set max simultaneous procs to 5, allow children to call CORE::fork()
    use Forks::Super MAX_PROC => 5, CHILD_FORK_OK => -1;

or they may be set explicitly in the code:

    $Forks::Super::ON_BUSY = 'queue';
    $Forks::Super::FH_DIR = "/home/joe/temp-ipc-files";

Module variables that may be of interest include:

Previous sections discussed the use of C<$Forks::Super::MAX_PROC>
and C<$Forks::Super::ON_BUSY>. Some other module variables that might
be of interest are

=over 4

=item C<$Forks::Super::MAX_PROC>

The maximum number of simultaneous background processes that can
be spawned by C<Forks::Super>. If a C<fork> call is attempted while
there are already at least this many active background processes,
the behavior of the C<fork> call will be determined by the
value in C<$Forks::Super::ON_BUSY> or by the C<on_busy> option passed
to the C<fork> call.

This value will be ignored during a C<fork> call if the C<force> 
option is passed to C<fork> with a non-zero value. The value might also
not be respected if the user supplies a code reference in the
C<can_launch> option and the user-supplied code does not test
whether there are already too many active proceeses.

=item C<$Forks::Super::ON_BUSY = 'block' | 'fail' | 'queue'>

Determines behavior of a C<fork> call when the system is too
busy to create another background process. 

If this value is set
to C<block>, then C<fork> will wait until the system is no
longer too busy and then launch the background process.
The return value will be a normal process ID value (assuming
there was no system error in creating a new process).

If the value is set to C<fail>, the C<fork> call will return
immediately without launching the background process. The return
value will be C<-1>. A C<Forks::Super::Job> object will not be
created.

If the value is set to C<queue>, then the C<fork> call
will create a "deferred" job that will be queued and run at
a later time. Also see the C<queue_priority> option to C<fork>
to set the urgency level of a job in case it is deferred.
The return value will be a large and negative
job ID. 

This value will be ignored in favor of an C<on_busy> option
supplied to the C<fork> call.

=item C<$Forks::Super::CHILD_FORK_OK = -1 | 0 | +1>

Spawning a child process from another child process with this
module has its pitfalls, and this capability is disabled by
default: you will get a warning message and the C<fork()> call
will fail if you try it.

To override hits behavior, set C<$Forks::Super::CHILD_FORK_OK> to 
a non-zero value. Setting it to a positive value will allow
you to use all the functionality of this module from a child
process (with the obvious caveat that you cannot C<wait> on the
child process or a child process from the main process).

Setting C<$Forks::Super::CHILD_FORK_OK> to a negative value will 
disable the functionality of this module but will 
reenable the classic Perl C<fork()> system call from child
processes.

=item C<$Forks::Super::DEBUG, Forks::Super::DEBUG>

To see the internal workings of the C<Forks> module, set
C<$Forks::Super::DEBUG> to a non-zero value. Information messages
will be written to the C<Forks::Super::DEBUG> filehandle. By default
C<Forks::Super::DEBUG> is aliased to C<STDERR>, but it may be reset
by the module user at any time.

Debugging behavior may be overridden for specific jobs
if the C<debug> or C<undebug> option is provided to C<fork>.

=item C<%Forks::Super::CHILD_STDIN>

=item C<%Forks::Super::CHILD_STDOUT>

=item C<%Forks::Super::CHILD_STDERR>

In jobs that request access to the child process filehandles,
these hash arrays contain filehandles to the standard input
and output streams of the child. The filehandles for particular
jobs may be looked up in these tables by process ID or job ID
for jobs that were deferred.

Remember that from the perspective of the parent process,
C<$Forks::Super::CHILD_STDIN{$pid}> is an output filehandle (what you
print to this filehandle can be read in the child's STDIN),
and C<$Forks::Super::CHILD_STDOUT{$pid}> and C<$Forks::Super::CHILD_STDERR{$pid}>
are input filehandles (for reading what the child wrote
to STDOUT and STDERR).

As with any asynchronous communication scheme, you should
be aware of how to clear the EOF condition on filehandles
that are being simultaneously written to and read from by
different processes. A scheme like this works on most systems:

    # in parent, reading STDOUT of a child
    for (;;) {
        while (<{$Forks::Super::CHILD_STDOUT{$pid}}>) {
          print "Child $pid said: $_";
        }

        # EOF reached, but child may write more to filehandle later.
        sleep 1;
        seek $Forks::Super::CHILD_STDOUT{$pid}, 0, 1;
    }

=item C<@Forks::Super::ALL_JOBS>, C<%Forks::Super::ALL_JOBS>

List of all C<Forks::Super::Job> objects that were created from C<fork()> calls,
including deferred and failed jobs. Both process IDs and job IDs
(for jobs that were deferred at one time) can be used to look
up Job objects in the %Forks::Super::ALL_JOBS table.

=item C<$Forks::Super::QUEUE_INTERRUPT>

On systems with mostly-working signal frameworks, this
module installs a signal handler the first time that a
task is deferred. The signal that is trapped is
defined in the variable C<$Forks::Super::QUEUE_INTERRUPT>.
The default value is C<USR1>, and it may be overridden 
directly or set on module import

    use Forks::Super QUEUE_INTERRUPT => 'TERM';
    $Forks::Super::QUEUE_INTERRUPT = 'USR2';

You would only worry about resetting this variable
if you (including other modules that you import) are
making use of an existing C<SIGUSR1> handler.



=back

=head1 DIAGNOSTICS

=over 4

=item C<fork() not allowed in child process ...>

=item C<Forks::Super::fork() call not allowed in child process ...>

When the package variable C<$Forks::Super::CHILD_FORK_OK> is zero, this package does not
allow the C<fork()> method to be called from a child process. 
Set L<C<< $Forks::Super::CHILD_FORK_OK >>|/"MODULE VARIABLES"> 
to change this behavior.

=item C<quick timeout>

A job was configured with a timeout/expiration time such that the 
deadline for the job occurred before the job was even launched. The job
was killed immediately after it was spawned.

=item C<Job start/Job dependency E<lt>nnnE<gt> for job E<lt>nnnE<gt> is invalid. Ignoring.>

A process id or job id that was specified as a C<depend_on> or C<depend_start>
option did not correspond to a known job.

=item C<Job E<lt>nnnE<gt> reaped before parent initialization.>

A child process finished quickly and was reaped by the parent process C<SIGCHLD>
handler before the parent process could even finish initializing the job state.
The state of the job in the parent process might be unavailable or corrupt 
for a short time, but eventually it should be all right.

=item C<interprocess filehandles not available>

=item C<could not open filehandle to provide child STDIN/STDOUT/STDERR>

=item C<child was not able to detect STDIN file ... Child may not have any input to read.>

=item C<could not open filehandle to write child STDIN>

=item C<could not open filehandle to read child STDOUT/STDERR>

Initialization of filehandles for a child process failed. The child process
will continue, but it will be unable to receive input from the parent through
the C<$Forks::Super::CHILD_STDIN{pid}> filehandle, or pass output to the parent through the
filehandles C<$Forks::Super::CHILD_STDOUT{PID}> AND C<$Forks::Super::CHILD_STDERR{pid}>. 

=item C<exec option used, timeout option ignored>

A C<fork> call was made using the incompatible options C<exec> and C<timeout>.

=back

=head1 INCOMPATIBILITIES

Some features use the C<alarm> function and custom
C<SIGALRM> handlers in the child processes. Using other
modules that employ this functionality may cause
undefined behavior. Systems and versions that do not
implement the C<alarm> function (like MSWin32 prior to
Perl v5.7) will not be able to use these features.

The first time that a task is deferred, by default this
module will try to install a C<SIGUSR1> handler. See
the description of C<$Forks::Super::QUEUE_INTERRUPT>
under L</"MODULE VARIABLES"> for changing this behavior
if you intended to use a C<SIGUSR1> handler for
something else.

=head1 DEPENDENCIES

The C<bg_eval> function requires L<YAML>.

Otherwise, there are no hard dependencies 
on non-core modules. Some features, especially operating-system
specific functions,
depend on some modules (C<Win32::API> and C<Win32::Process>
for Wintel systems, for example), but the module will
compile without those modules. Attempts to use these features
without the required modules will be silently ignored.

=head1 BUGS AND LIMITATIONS

A typical script using this module will have a lot of
behind-the-scenes signal handling as child processes
finish and are reaped. These frequent interruptions can
affect the execution of your program. For example, in
this script:

    1: use Forks::Super;
    2: fork(sub => sub { sleep 2 });
    3: sleep 5;
    4: # ... program continues ...

the C<sleep> call in line 3 is probably going to get
interrupted before 5 seconds have elapsed as the end
of the child process spawned in line 2 will interrupt
execution and invoke the SIGCHLD handler.
In some cases there are tedious workarounds:

    3a: $stop_sleeping_at = time + 5;
    3b: sleep 1 while time < $stop_sleeping_at;

It should be noted that signal handling in Perl is much
improved with version 5.7.3, and the problems caused by
such interruptions are much more tractable than they
used to be.

The system implementation of fork'ing and wait'ing varies
from platform to platform. It is possible that this module
or certain features will not work as advertised. Please
report any problems you encounter to E<lt>mob@cpan.orgE<gt>
and I'll see what I can do about it.

=cut

=head1 SEE ALSO

There are reams of other modules on CPAN for managing background
processes. See Parallel::*, Proc::Parallel, Proc::Fork, 
Proc::Launcher.

Inspiration for C<bg_eval> function from L<Acme::Fork::Lazy>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2010, Marty O'Brien.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut



TODO in future releases: See TODO file.

Undocumented:
$Forks::Super::Job::self              available in child process. Reference to the job object that launched the process.

$SOCKET_READ_TIMEOUT    in _read_socket, length of time to wait for input on the sockethandle being read
                                      before returning  undef 

fork { retries => $n }                if CORE::fork() fails, retry up to $n times
