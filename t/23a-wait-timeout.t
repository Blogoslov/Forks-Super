use Forks::Super ':test';
use Test::More tests => 9;
use POSIX ':sys_wait_h';
use strict;
use warnings;

##################################################################
# wait(timeout)

my $t = Time::HiRes::time();
my $pid = fork { sub => sub { sleep 2 } };
my $p = wait;
$t = Time::HiRes::time() - $t;
ok($t >= 1.95, "wait waits for job to finish ${t}s expected ~2s");
ok($p == $pid, "wait returns pid of job");

$t = Time::HiRes::time();
$pid = fork { sub => sub { sleep 2 } };
$p = wait 8;
$t = Time::HiRes::time() - $t;
ok($t >= 1.95 && $t <= 5.5,            ### 3 ### was 2.85 obs 3.14,3.16,3.93
   "wait with long timeout returned when job finished ${t}s expected ~2s");
ok($p == $pid, "wait with long timeout returns pid of job $p==$pid");
$p = wait 4;
ok($p == -1, "wait returns $p==-1 when nothing to wait for");

$t = Time::HiRes::time();
$pid = fork { sub => sub { sleep 6 } };
my $t2 = Time::HiRes::time();
$p = wait 3;
my $t3 = Time::HiRes::time();
($t,$t2) = ($t3-$t,$t3-$t2);
ok($t2 >= 2.95 && $t2 <= 4.05,        ### 6 ###
   "wait with short timeout returns at end of timeout ${t}s ${t2}s "
   . "expected ~3s");

ok($p == &Forks::Super::Wait::TIMEOUT, "wait timeout returns TIMEOUT");
$t2 = Time::HiRes::time();
$p = wait 9;
$t2 = Time::HiRes::time() - $t2;
ok($t2 >= 2.25 && $t2 <= 5.5,           ### 8 ### was 2.85, obs 3.08,3.18,4.37
   "subsequent wait with long timeout returned when job finished "
   . "in ${t2}s, expected ~3s");
ok($p == $pid, 
   "wait with subsequent long timeout returns $p==$pid pid of job");

waitall;
