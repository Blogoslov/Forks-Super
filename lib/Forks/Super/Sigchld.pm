#
# Forks::Super::Sigchld - SIGCHLD handler for Forks::Super module
#

package Forks::Super::Sigchld;
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(:all);
use POSIX ':sys_wait_h';
use strict;
use warnings;



our $_SIGCHLD = 0;
our $_SIGCHLD_CNT = 0;
our (@CHLD_HANDLE_HISTORY, @SIGCHLD_CAUGHT) = (0);
our $SIG_DEBUG = $ENV{SIG_DEBUG};

#
# default SIGCHLD handler to reap completed child
# processes for Forks::Super
#
# may also be invoked synchronously with argument -1
# if we are worried that some previous CHLD signals
# were not handled correctly.
#
sub handle_CHLD {
  $SIGCHLD_CAUGHT[0]++;
  my $sig = shift;
  # poor man's synchronization
  $_SIGCHLD_CNT++;
  $_SIGCHLD++;
  if ($_SIGCHLD > 1) {
    if ($SIG_DEBUG) {
      use Time::HiRes;
      my $z = Time::HiRes::gettimeofday() - $^T;
      push @CHLD_HANDLE_HISTORY, "synch $$ $_SIGCHLD $_SIGCHLD_CNT $sig $z\n";
    }
    $_SIGCHLD--;
    return;
  }

  if ($SIG_DEBUG) {
    use Time::HiRes;
    my $z = Time::HiRes::gettimeofday() - $^T;
    push @CHLD_HANDLE_HISTORY, "start $$ $_SIGCHLD $_SIGCHLD_CNT $sig $z\n";
  }
  if ($sig ne "-1" && $DEBUG) {
    debug("Forks::Super::handle_CHLD(): $sig received");
  }

  my $nhandled = 0;

  for (;;) {
    my $pid = -1;
    my $old_status = $?;
    my $status = $old_status;
    for (my $tries=1; !isValidPid($pid) && $tries <= 3; $tries++) {
      $pid = CORE::waitpid -1, WNOHANG;
      $status = $?;
    }
    $? = $old_status;
    last if !isValidPid($pid);

    $nhandled++;

    if (defined $Forks::Super::ALL_JOBS{$pid}) {
      $Forks::Super::Queue::_REAP = 1;
      debug("Forks::Super::handle_CHLD(): ",
	    "preliminary reap for $pid status=$status") if $DEBUG;
      if ($SIG_DEBUG) {
	use Time::HiRes;
	my $z = Time::HiRes::gettimeofday() - $^T;
	push @CHLD_HANDLE_HISTORY, 
	  "reap $$ $_SIGCHLD $_SIGCHLD_CNT <$pid> $status $z\n";
      }

      $Forks::Super::Queue::_REAP = 1;
      my $j = $Forks::Super::ALL_JOBS{$pid};
      $j->{status} = $status;
      $j->_mark_complete;
    } else {
      # There are (at least) two reasons that we get to this code branch:
      #
      # 1. A child process completes so quickly that it is reaped in 
      #    this subroutine *before* the parent process has finished 
      #    initializing its state.
      #    Treat this as a bastard pid. We'll check later if the 
      #    parent process knows about this process.
      # 2. In Cygwin, the system sometimes fails to clean up the process
      #    correctly. I notice this mainly with deferred jobs.

      debug("Forks::Super::handle_CHLD(): got CHLD signal ",
	    "but can't find child to reap; pid=$pid") if $DEBUG;

      Forks::Super::_you_bastard($pid, $status);
    }
    $Forks::Super::Queue::_REAP = 1;
  }
  if ($SIG_DEBUG) {
    use Time::HiRes;
    my $z = Time::HiRes::gettimeofday() - $^T;
    push @CHLD_HANDLE_HISTORY, "end $$ $_SIGCHLD $_SIGCHLD_CNT $sig $z\n";
  }
  $_SIGCHLD--;
  Forks::Super::Queue::check_queue() if $nhandled > 0;
  return;
}


1;
