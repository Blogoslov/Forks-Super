use Forks::Super ':test';
use Test::More tests => 19;
use Carp;
use strict;
use warnings;

$SIG{ALRM} = sub { die "Timeout\n" };
eval { alarm 120 };

#
# test that jobs respect their dependencies.
# a job won't start before another job starts that
# is in its "depend_start" list, and a job will
# wait for all of the jobs in its "depend_on"
# list to complete before starting.
#

# dependency with queue

$Forks::Super::MAX_PROC = 20;
$Forks::Super::ON_BUSY = "queue";

my $pid1 = fork { sub => sub { sleep 5 } };
my $t = Forks::Super::Util::Time();
my $pid2 = fork { sub => sub { sleep 5 } , depend_on => $pid1, 
		    queue_priority => 10 };
my $pid3 = fork { sub => sub { }, queue_priority => 5 };
$t = Forks::Super::Util::Time() - $t;
ok($t <= 1.95, "fast return ${t}s for queued job, expected <= 1s"); ### 1 ###
my $j1 = Forks::Super::Job::get($pid1);
my $j2 = Forks::Super::Job::get($pid2);
my $j3 = Forks::Super::Job::get($pid3);

ok($j1->{state} eq "ACTIVE", "first job active");
ok($j2->{state} eq "DEFERRED", "second job deferred");
waitall;
ok($j1->{end} <= $j2->{start}, "job 2 did not start before job 1 ended");
ok($j3->{start} < $j2->{start}, "job 3 started before job 2");




$Forks::Super::MAX_PROC = 20;
$Forks::Super::ON_BUSY = "block";
$pid1 = fork { sub => sub { sleep 5 } };
ok(isValidPid($pid1), "job 1 started");
$j1 = Forks::Super::Job::get($pid1);

$t = Forks::Super::Util::Time();
$pid2 = fork { sub => sub { sleep 5 } , depend_on => $pid1 };
$j2 = Forks::Super::Job::get($pid2);
ok($j1->{state} eq "COMPLETE", "job 1 complete when job 2 starts");
$pid3 = fork { sub => sub { } };
$j3 = Forks::Super::Job::get($pid3);
$t = Forks::Super::Util::Time() - $t;
ok($t >= 4.75, "job 2 took ${t}s to start expected >5s"); ### 8 ###

ok($j2->{state} eq "ACTIVE", "job 2 still running");
waitall;
ok($j1->{end} <= $j2->{start}, "job 2 did not start before job 1 ended");
ok($j3->{start} >= $j2->{start}, "job 3 started after job 2");




$Forks::Super::MAX_PROC = 2;
$Forks::Super::ON_BUSY = "queue";

ok( isValidPid(  fork( {sub => sub { sleep 2 }} ) ) , "fork successful");
$pid1 = fork { sub => sub { sleep 3 } };
$j1 = Forks::Super::Job::get($pid1);
ok($j1->{state} eq "ACTIVE", "first job running");

$pid2 = fork { sub => sub { sleep 3 }, queue_priority => 0 };
$j2 = Forks::Super::Job::get($pid2);
ok($j2->{state} eq "DEFERRED", "job 2 waiting");

$pid3 = fork { sub => sub { sleep 1 }, depend_on => $pid2, 
	       queue_priority => 1 };
$j3 = Forks::Super::Job::get($pid3);
ok($j3->{state} eq "DEFERRED", "job 3 waiting");

my $pid4 = fork { sub => sub { sleep 2 }, 
		  depend_start => $pid2, queue_priority => -1 };
my $j4 = Forks::Super::Job::get($pid4);
ok($j4->{state} eq "DEFERRED", "job 4 waiting");

# without calling run_queue(), first set of jobs might 
# finish before queue is examined
Forks::Super::Queue::run_queue();

waitall;
ok($j4->{start} >= $j2->{start}, "job 4 respected depend_start for job2");
ok($j3->{start} >= $j2->{end}, "job 3 respected depend_on for job2");
ok($j4->{start} < $j3->{start}, "low priority job 4 start before job 3");

eval { alarm 0 };
