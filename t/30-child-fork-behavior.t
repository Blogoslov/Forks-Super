use Forks::Super ':test';
use Test::More tests => 6;
use strict;
use warnings;

#
# test different options for child processes that
# try to call fork.
#

$Forks::Super::CHILD_FORK_OK = 0;
my $pid1 = fork();
if ($pid1 == 0) {
  &try_to_fork_from_child;
  Forks::Super::child_exit 0;
}
my $p = waitpid $pid1,0;
ok($p == $pid1);
ok(23 == $? >> 8, "child failed to fork as expected");


$Forks::Super::CHILD_FORK_OK = 1;
my $pid2 = fork();
if ($pid2 == 0) {
  &try_to_fork_from_child;
  Forks::Super::child_exit 0;
}
$p = waitpid $pid2, 0;
ok($p == $pid2);
ok(0 == $?, "child fork was allowed");

$Forks::Super::CHILD_FORK_OK = -1;
my $pid3 = fork();
if ($pid3 == 0) {
  &try_to_fork_from_child;
  Forks::Super::child_exit 0;
}
$p = wait;
ok($p == $pid3);
ok(25 == $? >> 8, "child fork used CORE::fork");



sub try_to_fork_from_child {
  my $child_fork_pid = fork();
  if (not defined $child_fork_pid  or  !_isValidPid($child_fork_pid)) {
    # child fork failed.
    Forks::Super::child_exit 23;
  }
  if (_isValidPid($child_fork_pid)) {
    my $j = Forks::Super::Job::_get($child_fork_pid);
    if (not defined $j) {
      # normal (CORE::) fork. No child job created.
      Forks::Super::child_exit 25;
    }
  }
}

__END__
-------------------------------------------------------

Feature:	Prevent fork from children

What to test:	fork from child fails when CHILD_FORK_OK==0
		fork from child OK when CHILD_FORK_OK==1
		fork from child calls CORE::fork() when CFO==-1

-------------------------------------------------------
