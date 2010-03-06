use Forks::Super ':test';
use Test::More tests => 15;
use strict;
use warnings;

#
# if configured the right way, jobs should go to a
# job queue for deferred launch when the system is
# too busy.
#

$Forks::Super::MAX_PROC = 2;
$Forks::Super::ON_BUSY = "queue";

ok(@Forks::Super::Queue::QUEUE == 0, "$$\\initial queue is empty");
my $pid1 = fork { sub => sub { sleep 5 } };
my $pid2 = fork { sub => sub { sleep 5 } };
ok(isValidPid($pid1) && isValidPid($pid2), "two successful fork calls");
my $pid3 = fork { sub => sub { sleep 5 } };
ok(@Forks::Super::Queue::QUEUE == 1, "third fork call is deferred");
ok($pid3 < -10000, "deferred job has large negative id");
my $j = Forks::Super::Job::get($pid3);
ok(defined $j, "job object avail for deferred job");
ok($j->{state} eq "DEFERRED", "deferred job in DEFERRED state");

waitall;

ok($j->is_complete, "waitall waits for deferred job to complete");
ok($j->{real_pid} != $j->{pid}, "real_pid != pid for deferred job");
ok(isValidPid($j->{real_pid}), "real_pid is valid pid");

############################################

# check priorities

$Forks::Super::MAX_PROC = 2;
$Forks::Super::ON_BUSY = "queue";

my $pid = fork { sub => sub { sleep 5 } };
$pid2 = fork { sub => sub { sleep 4 } };
ok(isValidPid($pid) && isValidPid($pid2), "two successful fork calls");

my $ordinary = fork { sub => sub { sleep 3 }, queue_priority => 0 };
$^O eq "MSWin32" ? Forks::Super::pause(1) : sleep 1;
my $mild = fork { sub => sub { sleep 3 }, queue_priority => -1 };
$^O eq "MSWin32" ? Forks::Super::pause(1) : sleep 1;
my $urgent = fork { sub => sub { sleep 3 } , queue_priority => 1 };

ok(!isValidPid($ordinary) && !isValidPid($mild) && !isValidPid($urgent),
   "three deferred jobs created");
ok($ordinary > $mild && $mild > $urgent, 
	"defered jobs created in right order");

waitall;

my $jo = Forks::Super::Job::get($ordinary);
my $jm = Forks::Super::Job::get($mild);
my $ju = Forks::Super::Job::get($urgent);

ok($jo->{state} eq "REAPED" && $jm->{state} eq "REAPED" &&
   $ju->{state} eq "REAPED",
   "deferred jobs reaped after waitall");
if (Forks::Super::CONFIG("Time::HiRes")) {
  ok($jo->{start} > $ju->{start}, "respect queue priority HR jm=" . $jm->{start}
	. ",jo=" . $jo->{start} . ",ju=" . $ju->{start});
  ok($jm->{start} > $jo->{start}, "respect queue priority start HR"); ### 15 HR ###

  # can't guarantee the order that the jobs will be reaped,
  # so don't test whether the end times are in the expected order.

} else {
  ok($jo->{start} >= $ju->{start}, "respect queue priority");
  ok($jm->{start} >= $jo->{start}, "respect queue priority");
}
