use Forks::Super ':test';
use Test::More tests => 3;
use strict;
use warnings;

#
# 60-os.t
#
# test features that interact with the operating system,
# like setting the priority of a background process
# or setting the CPU affinity of a background process
#

SKIP: {
  skip "getpriority() not avail on Win32", 2 if $^O eq "MSWin32";
  my $pid1 = fork { sub => sub { sleep 10 } };
  sleep 1;
  my $p1 = getpriority(0,$pid1);
  my $pid2 = fork { sub => sub { sleep 10 }, os_priority => $p1 + 3 };
  sleep 1;
  my $p2 = getpriority(0,$pid2);
  ok($p1 != $p2);
  ok($p2 == $p1 + 3);
}

my $pid3 = fork { sub => sub { sleep 5 },  cpu_affinity => 0x02 };
ok(_isValidPid($pid3), "valid pid attempting to use only 2nd CPU");

waitall;
