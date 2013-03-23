use Forks::Super ':test';
use Test::More tests => 14;
use strict;
use warnings;

$Devel::Trace::TRACE = 0;

# exercise synchronization facilities in Forks::Super

my $ipc_dir = Forks::Super::Job::Ipc::_choose_dedicated_dirname();
if (! eval {$ipc_dir = Cwd::abs_path($ipc_dir)}) {
    $ipc_dir = Cwd::getcwd() . "/" . $ipc_dir;
}
($ipc_dir) = $ipc_dir =~ /(.*)/;
Forks::Super::Job::Ipc::set_ipc_dir($ipc_dir);

my $pid = fork { sync => 1, timeout => 10 };
if ($pid == 0) {
    Time::HiRes::sleep(0.25) while Forks::Super::Job->acquireAndRelease(0,0);
    Forks::Super::Job->acquire(0);
    sleep 5;
    exit;
}
ok($pid->{_sync} && $pid->{_sync}{count} == 1,
   "job has _sync object, correct count");
diag("sync implementation is ", $pid->{_sync}{implementation});

my $t = Time::HiRes::time();
ok($pid->acquire(0,10), "parent acquires lock");
$t = Time::HiRes::time() - $t;
ok($t <= 1.0, "parent acquires lock quickly ${t}s expected <1s");
ok(0 > $pid->acquire(0,10), "parent already has lock");
sleep 2;
ok($pid->release(0), "parent releases lock");
ok(!$pid->release(0), "parent already released lock");

Time::HiRes::sleep(0.25) while $pid->is_active && $pid->acquireAndRelease(0,0);
$t = Time::HiRes::time();
ok(! $pid->acquire(0, 2), "parent fails to acquire lock in 2s");
$t = Time::HiRes::time() - $t;
ok($t > 1.50 && $t < 3.5, 
   "acquire with timeout respected timeout took ${t}s expected ~2s");
wait;

##################################################################

$pid = fork { sync => 'PCN', timeout => 10 };
if ($pid == 0) {
    Forks::Super::Job->acquire(0);
    Forks::Super::Job->release(1);
    exit;
}
ok($pid->{_sync} && $pid->{_sync}{count}==3, 
   "job has _sync object, correct count");

ok(0 > $pid->acquire(0), 'job already has resource 0');
ok(! $pid->acquire(1,5), 'resource 1 is locked even after 5s');
ok($pid->release(0),     'resource 0 is released');
$t = Time::HiRes::time();
ok($pid->acquire(1,2),   'resource 1 can be acquired now');
$t = Time::HiRes::time() - $t;
ok($t < 1.5, "resource 1 was acquired quickly. Took ${t}s, expected <1s");

##################################################################



