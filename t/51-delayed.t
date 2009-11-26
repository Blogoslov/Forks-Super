use Forks::Super ':test';
use Test::More tests => 19;
use strict;
use warnings;

#
# test that "delay" and "start_after" options are
# respected by the fork() call. Delayed jobs should
# go directly to the job queue.
#

# is delay tag respected ?
$Forks::Super::ON_BUSY = "queue";

my $now = Forks::Super::Time();
my $future = Forks::Super::Time() + 10;

my $p1 = fork { sub => sub { sleep 3 } , delay => 5 };
my $p2 = fork { sub => sub { sleep 3 } , start_after => $future };
ok($p1 < -10000, "fork to queue");
ok($p2 < -10000, "fork to queue");
my $j1 = Forks::Super::Job::get($p1);
my $j2 = Forks::Super::Job::get($p2);
ok($j1->{state} eq "DEFERRED", "deferred job has DEFERRED state");
ok($j2->{state} eq "DEFERRED", "deferred job has DEFERRED state");
ok(!defined $j1->{start}, "deferred job has not started");
waitall;
ok($j1->{start} >= $now + 5, "deferred job started after delay");
ok($j2->{start} >= $future, "deferred job started after delay");
ok($j1->{start} - $j1->{created} >= 5, "job start time after creation time");
ok($j2->{start} - $j2->{created} >= 9.9,
   "j2 created $j2->{created}, started $j2->{start}, expected 10s diff");

$Forks::Super::ON_BUSY = "block";
$now = time;

my $t = time;
$p1 = fork { sub => sub { sleep 3 } , delay => 5 };
$t = time - $t;
ok($t >= 4, "delayed job blocked");
ok(isValidPid($p1), "delayed job blocked and ran");
$j1 = Forks::Super::Job::get($p1);
ok($j1->{state} eq "ACTIVE", "state of delayed job is ACTIVE");

$future = time + 10;
$t = time;
$p2 = fork { sub => sub { sleep 3 } , start_after => $future };
$t = time - $t;
ok($t >= 4, "start_after job blocked");
ok(isValidPid($p2), "start_after job blocked and ran");
$j2 = Forks::Super::Job::get($p2);
ok($j2->{state} eq "ACTIVE", "job ACTIVE after delay");

waitall;

ok($j1->{start} >= $now + 5, "job start was delayed");
ok($j2->{start} >= $future, "job start was delayed");
ok($j1->{start} - $j1->{created} >= 5, "job 1 waited >=5 seconds before starting");
my $j2_wait = $j2->{start} - $j2->{created};
ok($j2_wait >= 9, "job 2 waited $j2_wait >=9 seconds before starting");

__END__
-------------------------------------------------------

Feature:	Queue jobs with a future "start time"

What to test:	delay attribute is respected
		start_after attribute is respected

-------------------------------------------------------
