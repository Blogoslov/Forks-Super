use Forks::Super ':test';
use Test::More tests => 4;
use POSIX ':sys_wait_h';
use strict;
use warnings;

# Job::get, Job::getByName, and waitpid

my ($pid,$pid1,$pid2,$pid3,$j1,$j2,$j3,$p,$q,$t,@j,$p1,$p2,$p3);
our $TOL = $Forks::Super::SysInfo::TIME_HIRES_TOL || 0.0;

$Forks::Super::MAX_PROC = 20;
$Forks::Super::ON_BUSY = "queue";

$t = Time::HiRes::time();
$p1 = fork { sub => sub {sleep 3}, name => "dup1" };
$p2 = fork { sub => sub {sleep 2}, name => "dup1", delay => 2 };
$p3 = fork { sub => sub {sleep 1}, depend_start => "dup1", depend_on => $p2 };
$j1 = Forks::Super::Job::get($p1);
$j2 = Forks::Super::Job::get($p2);
$j3 = Forks::Super::Job::get($p3);
ok($j1->{state} eq 'ACTIVE' && $j2->{state} eq 'DEFERRED' 
	&& $j3->{state} eq 'DEFERRED',
   "jobs in correct states");
waitall;
ok($j3->{start} + $TOL >= $j1->{start} 
   && $j3->{start} + $TOL >= $j2->{start},
	"resepected depend_start by name");
ok($j2->{start} + $TOL >= $j1->{start} + 1.5,
   "respected depend_start+delay");
ok($j3->{start} + $TOL >= $j2->{end},
   "resepected depend_on with depend_start");
