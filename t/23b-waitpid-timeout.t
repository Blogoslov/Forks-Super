use Forks::Super ':test';
use Test::More tests => 10;
use POSIX ':sys_wait_h';
use strict;
use warnings;

##################################################################
# waitpid(target,flags,timeout)

my $t = Time::HiRes::gettimeofday();
my $pid = fork { sub => sub { sleep 2 } };
my $u = Time::HiRes::gettimeofday();
my $p = waitpid $pid, 0, 6;
my $h = Time::HiRes::gettimeofday();
($t,$u) = ($h-$t,$h-$u);
ok($t >= 1.95 && $u <= 5.25,      ### 10 ### was 3.0 obs 3.12,3.28,3.95
   "waitpid with long timeout returns when job finishes ${t}s ${u}s "
   . "expected ~2s"); 
ok($p == $pid, "waitpid returns pid on long timeout");
$t = Time::HiRes::gettimeofday();
$p = waitpid $pid, 0, 4;
$t = Time::HiRes::gettimeofday() - $t;
ok($t <= 1, "waitpid fast return ${t}s, expected <=1s");
ok($p == -1, "waitpid -1 when nothing to wait for");

$t = Time::HiRes::gettimeofday();
$pid = fork { sub => sub { sleep 4 } };
$u = Time::HiRes::gettimeofday();
$p = waitpid $pid, 0, 2;
$h = Time::HiRes::gettimeofday();
($t,$u) = ($h-$t,$h-$u);
ok($u >= 1.95 && $u <= 3.05,             ### 14 ###
   "waitpid short timeout returns at end of timeout ${t}s ${u}s expected ~2s");
ok($p == &Forks::Super::Wait::TIMEOUT, 
   "waitpid short timeout returns TIMEOUT");

$t = Time::HiRes::gettimeofday();
$p = waitpid $pid, WNOHANG, 2;
$t = Time::HiRes::gettimeofday() - $t;
ok($t <= 1, "waitpid no hang fast return took ${t}s, expected <=1s");
ok($p == -1, "waitpid no hang returns -1");

$t = Time::HiRes::gettimeofday();
$p = waitpid $pid, 0, 10;
$t = Time::HiRes::gettimeofday() - $t;
ok($t >= 1.01 && $t <= 4.15,              ### 18 ### was 2.85 obs 3.30,4.12
   "subsequent waitpid long timeout returned when job finished "
   ."${t}s expected ~2s");
ok($p == $pid, "subsequent waitpid long timeout returned pid");
waitall;