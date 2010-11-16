#
# Forks::Super::Sigchld - SIGCHLD handler for Forks::Super module
#

package Forks::Super::Sigchld;
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(:all);
use Forks::Super::Sighandler;
use POSIX ':sys_wait_h';
# use Time::HiRes;  # not installed on ActiveState 5.6 :-(
use strict;
use warnings;

our ($_SIGCHLD, $_SIGCHLD_CNT) = (0,0);
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
  local $!;
  $SIGCHLD_CAUGHT[0]++;
  my $sig = shift;
  $_SIGCHLD_CNT++;

  # poor man's synchronization
  $_SIGCHLD++;
  if ($_SIGCHLD > 1) {
    if ($SIG_DEBUG) {
      my $z = Time::HiRes::time() - $^T;
      push @CHLD_HANDLE_HISTORY, "synch $$ $_SIGCHLD $_SIGCHLD_CNT $sig $z\n";
    }
    $_SIGCHLD--;
    return;
  }

  if ($SIG_DEBUG) {
    my $z = Time::HiRes::time() - $^T;
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
	my $z = Time::HiRes::time() - $^T;
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
    my $z = Time::HiRes::time() - $^T;
    push @CHLD_HANDLE_HISTORY, "end $$ $_SIGCHLD $_SIGCHLD_CNT $sig $z\n";
  }
  $_SIGCHLD--;
  Forks::Super::Queue::check_queue() if $nhandled > 0;
  return;
}

1;

__END__


Signal handling, since v0.40

Where available, signals are used throughout Forks::Super.
Where they are not available (MSWin32), we still try to run
the "signal handlers" every once in a while.

Parent SIGCHLD handler:

    Indicates that a child process is finished. 
    Call CORE::waitpid and do an "internal reap"

Child SIGALRM handler:

    Indicates that a child has "timed out" or expired.
    Should cause a kill signal (HUP? TERM? QUIT? INT?) to be
    sent to any grandchild processes.

Parent SIGHUP|SIGINT|SIGTERM|SIGQUIT|SIGPIPE handlers

    If parent process is interrupted, we still want the parent
    to run "clean up" code, especially if IPC files 
    were used.

Parent periodic tasks [SIGUSR1 | SIGALRM]

    Parent processes have some periodic tasks that they
    should perform from time to time:
      - Examine the job queue and dispatch jobs
      - Clean the pipes -- do non-blocking read on any
        open pipe/sockethandles and buffer the input
      - Call SIGCHLD handler to reap jobs where we might
        have missed a SIGCHLD

Child periodic tasks

    Periodic tasks in the child
      - Clean pipes
      - Check if command has timed out yet.
      - See if a user's alarm has gone off

We want a framework where we can add and remove jobs
for the signal handlers to do at will. If end user
also wishes to add a signal handler, the framework
should be able to accomodate that, too. And transparently.

Let's spike it out ...




