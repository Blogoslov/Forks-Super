use Forks::Super ':test';
use Test::More tests => 7;
use POSIX ':sys_wait_h';
use strict;
use warnings;

# Job::get, Job::getByName, and waitpid

my ($pid,$pid1,$pid2,$pid3,$j1,$j2,$j3,$p,$q,$t,@j,$p1,$p2,$p3);

# named dependency
# first job doesn't really have any dependencies, should start right away
# second job depends on first job

$Forks::Super::MAX_PROC = 20;
$Forks::Super::ON_BUSY = "queue";

$p1 = fork { sub => sub { sleep 3 }, name => "simple2", delay => 3 };
$t = Time::HiRes::gettimeofday();
$p2 = fork { sub => sub { sleep 3 }, 
	depend_start => "simple2", queue_priority => 10 };
$p3 = fork { sub => sub {}, queue_priority => 5 };
$t = Time::HiRes::gettimeofday() - $t;
ok($t <= 1.5, "fast return for queued job ${t}s expected <= 1s"); ### 15 ###
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
$j3 = Forks::Super::Job::get($p3);
ok($j1->{state} eq 'DEFERRED' && $j2->{state} eq 'DEFERRED',
   "active/queued jobs in correct state");
waitall;
ok($j1->{start} <= $j2->{start}, "respected start dependency by name");
ok($j3->{start} < $j2->{start}, 
   "non-dependent job started before dependent job");

$t = Time::HiRes::gettimeofday();
$p1 = fork { sub => sub {sleep 3}, name => "circle1", depend_on => "circle2" };
my $t2 = Time::HiRes::gettimeofday();
$p2 = fork { sub => sub {sleep 3}, name => "circle2", depend_on => "circle1" };
my $t3 = Time::HiRes::gettimeofday();
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
ok($j1->{state} eq 'ACTIVE' && $j2->{state} eq 'DEFERRED',
   "jobs with apparent circular dependency in correct state");
my $t31 = Time::HiRes::gettimeofday();
waitall();
my $t4 = Time::HiRes::gettimeofday();
($t,$t2,$t3,$t31) = ($t4-$t,$t4-$t2,$t4-$t3,$t4-$t31);
ok($t > 5.5 && $t31 < 8.8,          ### 20 ### was 8.0 obs 8.08
   "Took ${t}s ${t2}s ${t3}s ${t31} for dependent jobs - expected ~6s"); 
ok($j1->{end} <= $j2->{start}, "handled circular dependency");

