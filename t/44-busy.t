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

my $t = time;
my $pid1 = fork { 'sub' => $sleepy };
my $pid2 = fork { 'sub' => $sleepy };
my $pid3 = fork { 'sub' => $sleepy };
$t = time - $t;
ok($t <= 1);
ok(_isValidPid($pid1) && _isValidPid($pid2) && _isValidPid($pid3));

$t = time;
my $pid4 = fork { 'sub' => $sleepy };
$t = time - $t;
ok($t >= 2);
ok(_isValidPid($pid4), "blocking fork returns valid pid $pid4");
waitall;

#######################################################

$Forks::Super::ON_BUSY = "fail";
$t = time;
$pid1 = fork { 'sub' => $sleepy };  # ok 1/3
$pid2 = fork { 'sub' => $sleepy };  # ok 2/3
$pid3 = fork { 'sub' => $sleepy };  # ok 3/3
$t = time - $t;
ok($t <= 1);
ok(_isValidPid($pid1) && _isValidPid($pid2) && _isValidPid($pid3));


$t = time;
$pid4 = fork { 'sub' => $sleepy };     # should fail .. already 3 procs
my $pid5 = fork { 'sub' => $sleepy };  # should fail
my $u = time - $t;
ok($u <= 1, "Took ${u}s expected fast fail 0-1s");
ok(!_isValidPid($pid4) && !_isValidPid($pid5));
waitall;
$t = time - $t;

ok($t >= 3 && $t <= 4, "Took ${t}s for all jobs to finish; expected 3-4");

#######################################################







__END__
-------------------------------------------------------

Feature[44]:	Don't launch when system is busy
			Too many active proc
			CPU load too high
		Block / Fail

What to test:	Set global MAX_PROC, MAX_LOAD parameters
		Set job specific max_proc, max_load parameters
			that override global
		Set global ON_BUSY
		Set job specific on_busy
                force flag runs job even on busy system

-------------------------------------------------------
