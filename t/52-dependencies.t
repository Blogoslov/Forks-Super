use Forks::Super ':test';
use Test::More tests => 19;
use Carp;
use strict;
use warnings;

alarm 120;
$SIG{ALRM} = sub { die "Timeout\n" };

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
my $t = time;
my $pid2 = fork { sub => sub { sleep 5 } , depend_on => $pid1, queue_priority => 10 };
my $pid3 = fork { sub => sub { }, queue_priority => 5 };
$t = time - $t;
ok($t <= 1, "quick return for queued job");
my $j1 = Forks::Super::Job::_get($pid1);
my $j2 = Forks::Super::Job::_get($pid2);
my $j3 = Forks::Super::Job::_get($pid3);

ok($j1->{state} eq "ACTIVE", "first job active");
ok($j2->{state} eq "DEFERRED", "second job deferred");
waitall;
ok($j1->{end} <= $j2->{start}, "job 2 did not start before job 1 ended");
ok($j3->{start} < $j2->{start}, "job 3 started before job 2");




$Forks::Super::MAX_PROC = 20;
$Forks::Super::ON_BUSY = "block";
$pid1 = fork { sub => sub { sleep 5 } };
ok(_isValidPid($pid1), "job 1 started");
$j1 = Forks::Super::Job::_get($pid1);

$t = time;
$pid2 = fork { sub => sub { sleep 5 } , depend_on => $pid1 };
$j2 = Forks::Super::Job::_get($pid2);
ok($j1->{state} eq "COMPLETE", "job 1 complete when job 2 starts");
$pid3 = fork { sub => sub { } };
$j3 = Forks::Super::Job::_get($pid3);
$t = time - $t;
ok($t >= 5, "job 2 took 5s to start");

ok($j2->{state} eq "ACTIVE", "job 2 still running");
waitall;
ok($j1->{end} <= $j2->{start}, "job 2 did not start before job 1 ended");
ok($j3->{start} >= $j2->{start}, "job 3 started after job 2");




$Forks::Super::MAX_PROC = 2;
$Forks::Super::ON_BUSY = "queue";

ok( _isValidPid(  fork( {sub => sub { sleep 2 }} ) ) );
$pid1 = fork { sub => sub { sleep 3 } };
$j1 = Forks::Super::Job::_get($pid1);
ok($j1->{state} eq "ACTIVE", "first job running");

$pid2 = fork { sub => sub { sleep 3 }, queue_priority => 0 };
$j2 = Forks::Super::Job::_get($pid2);
ok($j2->{state} eq "DEFERRED", "job 2 waiting");

$pid3 = fork { sub => sub { sleep 1 }, depend_on => $pid2, 
	       queue_priority => 1 };
$j3 = Forks::Super::Job::_get($pid3);
ok($j3->{state} eq "DEFERRED", "job 3 waiting");

my $pid4 = fork { sub => sub { sleep 2 }, 
		  depend_start => $pid2, queue_priority => -1 };
my $j4 = Forks::Super::Job::_get($pid4);
ok($j4->{state} eq "DEFERRED", "job 4 waiting");

# without calling run_queue(), first set of jobs might 
# finish before queue is examined
Forks::Super::run_queue();

waitall;
ok($j4->{start} >= $j2->{start}, "job 4 respected depend_start for job2");
ok($j3->{start} >= $j2->{end}, "job 3 respected depend_on for job2");
ok($j4->{start} < $j3->{start}, "low priority job 4 start before job 3");

alarm 0;

__END__
    $pid1 = fork { cmd => $job1 };
    $pid2 = fork { cmd => $job2, depend_on => $pid1 };            # put on queue until job 1 is complete
    $pid4 = fork { cmd => $job4, depend_start => [$pid2,$pid3] }; # put on queue until jobs 2 and 3 have started


__END__
-------------------------------------------------------

Feature:	Job start dependencies

		Make the system busy
		Create a job that will get deferred
		Create a job with start dependency
		Start time of 2nd job >= start time of 1st job

-------------------------------------------------------
