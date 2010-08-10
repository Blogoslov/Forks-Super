use Forks::Super ':test';
use Test::More tests => 5;
use strict;
use warnings;

# exercise fork { retries => ... } function

BEGIN {
  *Forks::Super::Job::_CORE_fork = *mockfork;
}

our $TIMES_TO_FAIL = 0;

sub mockfork {
  if ($TIMES_TO_FAIL-- > 0) {
    print STDERR "Mocking a failed fork ...\n";
    sleep 1;
    return undef;
  }
  print STDERR "Mock fork allowing fork to proceed ...\n";
  return CORE::fork();
}


# default retries is zero.
$TIMES_TO_FAIL = 1;
my $pid = fork( sub => sub { exit 0 } );
ok(!defined $pid, "default retries = 0");

$TIMES_TO_FAIL = 1;
$pid = fork { retries => 0, sub => sub { exit 0 } };
ok(!defined $pid, "retries = 0");

$TIMES_TO_FAIL = 1;
$pid = fork { retries => 1, sub => sub { exit 0 } };
ok(isValidPid($pid), "retries 1 succeeds");

$TIMES_TO_FAIL = 5;
$pid = fork { retries => 2, sub => sub { exit 0 } };
ok(!defined $pid, "retries 2 fails");

$TIMES_TO_FAIL = 5;
$pid = fork { retries => 10, sub => sub { exit 0 } };
ok(isValidPid($pid), "retries 10 succeeds");





