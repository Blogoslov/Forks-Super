use Forks::Super::Sync;
use Test::More tests => 28;
use strict;
use warnings;
select STDERR;
$| = 1;
select STDOUT;
$| = 1;

if ($^O eq 'cygwin') {
    require Config;
    if ($Config::Config{"d_flock"} && $Config::Config{"d_fcntl_can_lock"} &&
	$Config::Config{"d_flock"} eq 'define' &&
	$Config::Config{"d_fcntl_can_lock"} eq 'define') {

	diag q~
note for Cygwin users: I believe there is a flaw in recent
versions of Cygwin's flock implementation. If this test (or
t/57-sync.t) times out or hangs, you may have better luck
with a perl build configured *without* flock (e.g., building
from source after running  ./Configure -Ud_flock ). In that
case, perl will use  fcntl  to emulate flock.

~;

    }
}

{
    no warnings 'once';
    mkdir "t/out/07.$$";
    $Forks::Super::IPC_DIR = "t/out/07.$$";
}

sub test_implementation {
    my $implementation = shift;

    my $sync = Forks::Super::Sync->new(
	implementation => $implementation || 'Semaphlock',
	count => 3,
	initial => [ 'P', 'C', 'N' ]);

    my $impl = $sync ? $sync->{implementation} : '<none>';
    ok($sync, "sync object created ($impl)");               ### 1,10,19 ###
    my $pid = CORE::fork();
    $sync->releaseAfterFork($pid || $$);
    if ($pid == 0) {
	my $t = Time::HiRes::time();
	$sync->acquire(0); # blocks
	$t = Time::HiRes::time()-$t;

	$sync->acquire(2);
	$sync->release(0);
	$sync->release(1);
	$sync->release(2);
	exit;
    }

    sleep 2;
    my $z = $sync->acquire(1, 0.0);
    ok(!$z, 'resource 1 is held in child');                ### 2,11,20 ###

    $z = $sync->acquire(2, 0.0);
    ok($z==1, 'resource 2 acquired in parent')
	or diag("acquire(2,0) return values was: $z");

    $z = $sync->acquire(2);
    ok($z==-1, 'resource 2 already acquired in parent');

    $z = $sync->release(0);
    ok($z, 'resource 0 released in parent');

    $z = $sync->release(0);
    ok(!$z, 'resource 0 not held in parent');

    $z = $sync->release(2);
    ok($z, 'resource 2 released in parent');

    $z = $sync->acquireAndRelease(0, 10);
    ok($z, "acquired 0 in parent ($impl)")                 ### 8,17,26 ###
	or diag("error is $! $^E ", 0+$!);
    $z = $sync->release(0, 10) || 0;
    ok($z <= 0, ' and released 0 in parent');

    $sync->release(1);
    my $child = CORE::waitpid($pid, 0);
}

test_implementation('Semaphlock');

SKIP: {
    if ($^O eq 'MSWin32' || $^O eq 'cygwin') {
	if (! eval { require Forks::Super::Sync::Win32; 1 }) {
	    skip "Win32::Semaphore implementation not available", 9;
	}
	test_implementation('Win32');
    } else {
	test_implementation('IPCSemaphore');
    }
}

SKIP: {
    if (!eval "use Win32::Mutex;1") {
	skip "Win32::Mutex not available", 9;
    }
    if ($^O ne 'MSWin32' && $^O ne 'cygwin') {
	skip "Win32::Mutex implementation only for MSWin32, cygwin", 9;
    }
    test_implementation('Win32::Mutex');
}

CORE::wait for 1..3;

ok(1, 'waited on outstanding child processes');

unlink "t/out/07.$$/.sync*";
rmdir "t/out/07.$$";

1;
