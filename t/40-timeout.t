use Forks::Super ':test';
use Test::More tests => 18;
use strict;
use warnings;

#
# test that jobs respect deadlines for jobs to
# complete when the jobs specify "timeout" or
# "expiration" options
#

my $pid = fork { 'sub' => sub { sleep 5; exit 0 }, timeout => 3 };
my $t = Forks::Super::Time();
my $p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid);
ok($t < 5, "Timed out in ${t}s, should have taken 3-4");
ok($? != 0);

#######################################################

$pid = fork { 'sub' => sub { sleep 5; exit 0 }, timeout => 10 };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid);
ok($t < 9);
ok($? == 0);

#######################################################

$pid = fork { 'sub' => sub { sleep 5; exit 0 }, timeout => 0 };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid);
ok($t <= 1, "fast fail timeout=$t");
ok($? != 0);

#######################################################

my $now = Forks::Super::Time();
my $future = Forks::Super::Time() + 3;
$pid = fork { 'sub' => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid);
ok($t < 5, "should take about 3 seconds, took $t");
ok($? != 0);

#######################################################

$future = Forks::Super::Time() + 10;
$pid = fork { 'sub' => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid);
ok($t < 9);
ok($? == 0);

#######################################################

$future = Forks::Super::Time() - 5;
$pid = fork { 'sub' => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid);
ok($t <= 1, "expected fast fail took ${t}s");
ok($? != 0);

#######################################################




__END__
-------------------------------------------------------

Feature[40]:	fork with timeout

What to test:	child completes before alarm
		child does not complete before alarm
		relative (timeout) or absolute (expiration)
                negative timeout

-------------------------------------------------------
