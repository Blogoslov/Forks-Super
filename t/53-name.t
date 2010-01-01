use Forks::Super ':test';
use Test::More tests => 25;
use POSIX ':sys_wait_h';
use strict;
use warnings;

# Job::get, Job::getByName, and waitpid

my ($pid,$pid1,$pid2,$pid3,$j1,$j2,$j3,$p,$q,$t,@j,$p1,$p2,$p3);

$pid = fork { sub => sub {sleep 2}, name => "sleeper" };
$j1 = Forks::Super::Job::get($pid);
$j2 = Forks::Super::Job::get("sleeper");
ok($j1 eq $j2, "job get by name");
$p = waitpid "sleeper", 0;
ok($p == $pid, "waitpid by name");

$j3 = Forks::Super::Job::get("bogus name");
ok(!defined $j3, "job get by bogus name");
$p = waitpid "bogus name", 0;
ok($p == -1, "waitpid bogus name");

$pid1 = fork { sub => sub { sleep 3 }, name => "sleeperX" };
$pid2 = fork { sub => sub { sleep 3 }, name => "sleeperX" };
@j = Forks::Super::Job::getByName("sleeperX");
ok(@j == 2,"getByName dup");
@j = Forks::Super::Job::getByName("bogus");
ok(@j == 0, "getByName bogus");
$p = waitpid "sleeperX", WNOHANG;
ok($p == -1, "nonblock waitpid by name");
$p = waitpid "sleeperX", 0;
ok($p == $pid1 || $p == $pid2, "waitpid by dup name");
$q = waitpid "sleeperX", 0;
ok($p+$q == $pid1+$pid2, "waitpid by name second time");
$q = waitpid "sleeperX", 0;
ok($q == -1, "waitpid by name too many times");

if (Forks::Super::CONFIG("alarm")) {
    alarm 120;
    $SIG{ALRM} = sub { die "Timeout\n" };
}

$Forks::Super::MAX_PROC = 20;
$Forks::Super::ON_BUSY = "queue";

$p1 = fork { sub => sub { sleep 3 }, name => "simple" };
$t = Forks::Super::Time();
$p2 = fork { sub => sub { sleep 3 }, depend_on => "simple", queue_priority => 10 };
$p3 = fork { sub => sub { }, queue_priority => 5 };
$t = Forks::Super::Time() - $t;
ok($t <= 1.5, "quick return for queued job ${t}s expected <=1s");
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
$j3 = Forks::Super::Job::get($p3);
ok($j1->{state} eq 'ACTIVE' && $j2->{state} eq 'DEFERRED',
   "active/queued jobs in correct state");
waitall;
ok($j1->{end} <= $j2->{start}, "respected depend_on by name");
ok($j3->{start} < $j2->{start}, "non-dependent job started before dependent job");

$p1 = fork { sub => sub { sleep 3 }, name => "simple2", delay => 3 };
$t = Forks::Super::Time();
$p2 = fork { sub => sub { sleep 3 }, depend_start => "simple2", queue_priority => 10 };
$p3 = fork { sub => sub {}, queue_priority => 5 };
$t = Forks::Super::Time() - $t;
ok($t <= 1.5, "quick return for queued job ${t}s expected <= 1s");
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
$j3 = Forks::Super::Job::get($p3);
ok($j1->{state} eq 'DEFERRED' && $j2->{state} eq 'DEFERRED',
   "active/queued jobs in correct state");
waitall;
ok($j1->{start} <= $j2->{start}, "respected start dependency by name");
ok($j3->{start} < $j2->{start}, "non-dependent job started before dependent job");

$t = Forks::Super::Time();
$p1 = fork { sub => sub {sleep 3}, name => "circle1", depend_on => "circle2" };
$p2 = fork { sub => sub {sleep 3}, name => "circle2", depend_on => "circle1" };
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
ok($j1->{state} eq 'ACTIVE' && $j2->{state} eq 'DEFERRED',
   "jobs with apparent circular dependency in correct state");
waitall();
$t = Forks::Super::Time() - $t;
ok($t > 5.5 && $t < 7.5, "Took ${t}s for dependent jobs - expected ~6s");
ok($j1->{end} <= $j2->{start}, "handled circular dependency");

$t = Forks::Super::Time();
$p1 = fork { sub => sub {sleep 3}, name => "dup1" };
$p2 = fork { sub => sub {sleep 2}, name => "dup1", delay => 2 };
$p3 = fork { sub => sub {sleep 1}, depend_start => "dup1", depend_on => $p2 };
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
$j3 = Forks::Super::Job::get($p3);
ok($j1->{state} eq 'ACTIVE' && $j2->{state} eq 'DEFERRED' && $j3->{state} eq 'DEFERRED',
   "jobs in correct states");
waitall;
ok($j3->{start} >= $j1->{start} && $j3->{start} >= $j2->{start},"resepected depend_start by name");
ok($j2->{start} >= $j1->{start} + 1.5, "respected depend_start+delay");
ok($j3->{start} >= $j2->{end}, "resepected depend_on with depend_start");

if (Forks::Super::CONFIG("alarm")) {
    alarm 0;
}

