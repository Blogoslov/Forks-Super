use Forks::Super ':test';
use Test::More tests => 9;
use strict;
use warnings;

#
# test that jobs don't launch when the system is
# "too busy" (which so far means that there are
# already too many active subprocesses). Jobs that
# are too busy to start can either block or fail.
#

#######################################################

sub sleepy { sleep 3 }
my $sleepy = \&sleepy;

$Forks::Super::MAX_PROC = 3;
$Forks::Super::ON_BUSY = "block";


#### failure point 0.06, MSWin32 5.00. Was the system overloaded? ####

my $pid1 = fork { sub => $sleepy };
my $pid2 = fork { sub => $sleepy };
my $t = Forks::Super::Util::Time();
my $t0 = $t;
my $pid3 = fork { sub => $sleepy };
$t = Forks::Super::Util::Time() - $t;
ok($t <= 1.97, "$$\\three forks fast return ${t}s expected <1s"); ### 1 ###
ok(isValidPid($pid1) && isValidPid($pid2) && isValidPid($pid3),
   "forks successful");

my $t2 = Forks::Super::Util::Time();
my $pid4 = fork { sub => $sleepy };
my $t3 = Forks::Super::Util::Time();
($t2,$t0) = ($t3-$t2, $t3-$t0);
ok($t2 >= 2 || ($t0 > 3.0), "blocked fork took ${t}s expected >2s");
ok(isValidPid($pid4), "blocking fork returns valid pid $pid4"); ### 4 ###
waitall;

#######################################################

$Forks::Super::ON_BUSY = "fail";
$pid1 = fork { sub => $sleepy };  # ok 1/3
$pid2 = fork { sub => $sleepy };  # ok 2/3
$t = Forks::Super::Util::Time();
$pid3 = fork { sub => $sleepy };  # ok 3/3
$t = Forks::Super::Util::Time() - $t;
ok($t <= 1.9, "three forks no delay ${t}s expected <=1s"); ### 5 ###
ok(isValidPid($pid1) && isValidPid($pid2) && isValidPid($pid3),
   "three successful forks");


$t = Forks::Super::Util::Time();
$pid4 = fork { sub => $sleepy };     # should fail .. already 3 procs
my $pid5 = fork { sub => $sleepy };  # should fail
my $u = Forks::Super::Util::Time() - $t;
ok($u <= 1, "Took ${u}s expected fast fail 0-1s"); ### 7 ###
ok(!isValidPid($pid4) && !isValidPid($pid5), "failed forks");
waitall;
$t = Forks::Super::Util::Time() - $t;

ok($t >= 2.15 && $t <= 6,                    ### 9 ### was 4 obs 6.75!
   "Took ${t}s for all jobs to finish; expected 3-4"); 

#######################################################
