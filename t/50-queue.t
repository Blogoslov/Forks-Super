use Forks::Super ':test';
use Test::More tests => 17;
use strict;
use warnings;

#
# if configured the right way, jobs should go to a
# job queue for deferred launch when the system is
# too busy.
#

$Forks::Super::MAX_PROC = 2;
$Forks::Super::ON_BUSY = "queue";

ok(@Forks::Super::QUEUE == 0);
my $pid1 = fork { sub => sub { sleep 5 } };
my $pid2 = fork { sub => sub { sleep 5 } };
ok(_isValidPid($pid1) and _isValidPid($pid2));
my $pid3 = fork { sub => sub { sleep 5 } };
ok(@Forks::Super::QUEUE == 1);
ok($pid3 < -10000);
my $j = Forks::Super::Job::get($pid3);
ok(defined $j);
ok($j->{state} eq "DEFERRED");

waitall;

ok($j->is_complete);
ok($j->{real_pid} != $j->{pid});
ok(_isValidPid($j->{real_pid}));

############################################

# check priorities

$Forks::Super::MAX_PROC = 2;
$Forks::Super::ON_BUSY = "queue";

my $pid = fork { sub => sub { sleep 5 } };
$pid2 = fork { sub => sub { sleep 4 } };
ok(_isValidPid($pid) and _isValidPid($pid2));

my $ordinary = fork { sub => sub { sleep 3 }, queue_priority => 0 };
$^O eq "MSWin32" ? Forks::Super::pause(1) : sleep 1;
my $mild = fork { sub => sub { sleep 3 }, queue_priority => -1 };
$^O eq "MSWin32" ? Forks::Super::pause(1) : sleep 1;
my $urgent = fork { sub => sub { sleep 3 } , queue_priority => 1 };

ok(!_isValidPid($ordinary) && !_isValidPid($mild) && !_isValidPid($urgent));
ok($ordinary > $mild && $mild > $urgent);

waitall;

my $jo = Forks::Super::Job::get($ordinary);
my $jm = Forks::Super::Job::get($mild);
my $ju = Forks::Super::Job::get($urgent);

ok($jo->{state} eq "REAPED" and $jm->{state} eq "REAPED" and $ju->{state} eq "REAPED");
if (Forks::Super::CONFIG("Time::HiRes")) {
  ok($jo->{start} > $ju->{start}, "respect queue priority HR");
  ok($jm->{start} > $jo->{start}, "respect queue priority HR");
  ok($jo->{end} > $ju->{end}, "respect queue priority HR");
  ok($jm->{end} > $jo->{end}, "respect queue priority HR");
} else {
  ok($jo->{start} >= $ju->{start}, "respect queue priority");
  ok($jm->{start} >= $jo->{start}, "respect queue priority");
  ok($jo->{end} >= $ju->{end}, "respect queue priority");
  ok($jm->{end} >= $jo->{end}, "respect queue priority");
}
