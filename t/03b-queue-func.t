# exercise Forks::Super::Queue package

use Forks::Super::Queue;
use Test::More tests => 15;
use strict;
use warnings;

$Forks::Super::MAIN_PID = $$;
$Forks::Super::Job::INSIDE_END_QUEUE = 0;
$Forks::Super::CHILD_FORK_OK = 0;
Forks::Super::Queue::init();

# what to test:
#   return value from  get_default_priority  decreases with each call
#   queue_job
#      increases ~~@QUEUE
#      changes job status to DEFERRED
#      sets job->{queued}
#      sets job->{pid} to very negative number
#      makes entry in %ALL_JOBS
#      launch queue monitor, if it is not already launched
#
#   _get_deferred_jobs
#      returns deferred jobs
#      verify deferred jobs are on @QUEUE
#
#   run_queue / _attempt_to_launch_deferred_jobs
#      invokes job's  can_launch, {debug}, launch
#      sets launched job state to LAUNCHING
#
#   suspend_resume_jobs
#      invokes &{$job->{suspend}} on all jobs
#          calls  suspend  or  resume  method based on result

{
    package MockJob;
    our $launch_ncalls = 0;
    sub new {
	my $self = bless {}, 'MockJob';
	$self->{can_launch_ncalls} = 0;
	push @Forks::Super::ALL_JOBS, $self;
	return $self;
    }
    sub toString {
	my $self = shift;
	return join ";", map{"$_ => " . $self->{$_}} sort keys %$self;
    }
    sub can_launch {
	my $self = shift;
	$self->{can_launch_ncalls}++;
	return $self->{xxx_can_launch} || 0;
    }
    sub launch {
	my $self = shift;
	$self->{launch_ncalls}++;
	$MockJob::launch_ncalls++;
	$self->{sub} = sub { warn "HEY!\n" };
	$self->{state} = 'MOCK_COMPLETE';
	return $$ + $MockJob::launch_ncalls;
    }
}

ok(@Forks::Super::Queue::QUEUE == 0, 'initial queue is empty');
ok(!$Forks::Super::Queue::QUEUE_MONITOR_PID, "queue monitor not running");
$Forks::Super::Queue::INHIBIT_QUEUE_MONITOR = 1;
$Forks::Super::Queue::QUEUE_MONITOR_FREQ = 1;

my $j = new MockJob();
Forks::Super::Queue::queue_job($j);
ok($j->{state} eq 'DEFERRED', 'queued job in DEFERRED state');
ok($j->{queued} >= $^T && int($j->{queued})<=time,
   'queue time applied to job');
ok($j->{pid} < -10000, 'queued job pid is very negative');
ok(@Forks::Super::Queue::QUEUE == 1, 'queue has a job now');
ok($Forks::Super::Queue::QUEUE[0] eq $j, 'queue has new job');
#ok($Forks::Super::Queue::QUEUE_MONITOR_PID, 
#   'monitor running after job queued');
ok($j->{can_launch_ncalls} == 0, 'launch not attempted yet');
Forks::Super::Queue::run_queue();
ok($j->{can_launch_ncalls} > 0, 'launch attempted');

my $j2 = new MockJob();
Forks::Super::Queue::queue_job($j2);
ok(@Forks::Super::Queue::QUEUE == 2, 'queue has two jobs');
ok($Forks::Super::Queue::QUEUE[0] eq $j &&
   $Forks::Super::Queue::QUEUE[1] eq $j2, 'queue has old and new job');

my @d = Forks::Super::Queue::_get_deferred_jobs();
ok(@d==2 && $d[0] eq $j && $d[1] eq $j2,
   '_get_deferred_jobs returns deferred job');
$j->{xxx_can_launch} = 1;
sleep 2;
ok($MockJob::launch_ncalls == 0, 'job launch method was called');
Forks::Super::Queue::check_queue();
ok($MockJob::launch_ncalls > 0, 'job launch method was called');
Forks::Super::Queue::check_queue();
ok(@Forks::Super::Queue::QUEUE == 1 &&
   $Forks::Super::Queue::QUEUE[0] eq $j2, 'queue now only has new job');

############################################
