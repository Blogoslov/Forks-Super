use Forks::Super ':test';
use Test::More tests => 7;
use POSIX ':sys_wait_h';
use strict;
use warnings;

##################################################################
# waitall(timeout)

$Forks::Super::MAX_PROC = 3;
$Forks::Super::ON_BUSY = "queue";

my $callbacks = {};
#$callbacks = { queue => sub { print Forks::Super::Util::Ctime(), " job queued\n" },
#	       start => sub { print Forks::Super::Util::Ctime(), " job started\n" },
#	       finish => sub { print Forks::Super::Util::Ctime(), " job finished\n" } };


my $t4 = Time::HiRes::time();
my $p2 = fork { sub => sub { sleep 1 }, 
		callback => $callbacks };    # should take 1s
my $p1 = fork { sub => sub { sleep 6 }, 
		callback => $callbacks };    # should take 6s
my $p3 = fork { sub => sub { sleep 1 }, 
		callback => $callbacks };    # should take 1s
my $p4 = fork { sub => sub { sleep 15 } };   # should take 1s+15s
my $t5 = 0.5 * ($t4 + Time::HiRes::time());


my $t = Time::HiRes::time();
my $count = waitall 3.5 + ($t5 - $t);
$t = Time::HiRes::time() - $t5;
ok($count == 2, "waitall reaped $count==2 processes after 2 sec"); ### 20 ###
okl($t >= 3.33 && $t <= 4.05, "waitall respected timeout ${t}s expected ~3s");

$t = Time::HiRes::time();
$count = waitall 5 + ($t5 - $t);
$t = Time::HiRes::time() - $t5;
ok($count == 0, "waitall reaped $count==0 processes in next 1 sec"); ### 22 ###
okl($t >= 4.85 && $t <= 6.25,                ### 23 ### was 5.25 obs 
   "waitall respected timeout ${t}s expected ~5s");

$t = Time::HiRes::time();
$count = waitall 8 + ($t5 - $t);
$t = Time::HiRes::time() - $t5;
ok($count == 1,                             ### 24 ###
   "waitall reaped $count==1 process in next 3 sec t=$t");
okl($t >= 7.15 && $t <= 10.8,                ### 25 ### was 8.55 obs 8.56.10.77
   "waitall respected timeout ${t}s expected ~8s");

$t = Time::HiRes::time();
$count = waitall;
$t4 = Time::HiRes::time();
$t = $t4 - $t;
$t5 = $t4 - $t5;
ok($count == 1, Forks::Super::Util::Ctime() ### 26 ###
   ." waitall reaped $count==1 final process");
# ok($t5 < 13.5);
