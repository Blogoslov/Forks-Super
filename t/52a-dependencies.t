use Forks::Super ':test';
use Test::More tests => 5;
use Carp;
use strict;
use warnings;

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
my $t = Time::HiRes::gettimeofday();
my $pid2 = fork { sub => sub { sleep 5 } , depend_on => $pid1, 
		    queue_priority => 10 };
my $pid3 = fork { sub => sub { }, queue_priority => 5 };
$t = Time::HiRes::gettimeofday() - $t;
ok($t <= 1.95, "fast return ${t}s for queued job, expected <= 1s"); ### 1 ###
my $j1 = Forks::Super::Job::get($pid1);
my $j2 = Forks::Super::Job::get($pid2);
my $j3 = Forks::Super::Job::get($pid3);

ok($j1->{state} eq "ACTIVE", "first job active");
ok($j2->{state} eq "DEFERRED", "second job deferred");
waitall;
ok($j1->{end} <= $j2->{start}, "job 2 did not start before job 1 ended");
ok($j3->{start} < $j2->{start}, "job 3 started before job 2");

