use Test::More tests => 15;
use Forks::Super;
use strict;
use warnings;

# exercise the tied scalar behaviors of some Forks::Super::Queue variables.

$Forks::Super::MAIN_PID = $$;
Forks::Super::Queue::init();

SKIP: {

  if ($Forks::Super::Queue::INHIBIT_QUEUE_MONITOR) {
    skip "queue monitor disabled", 15;
  }

  # $Forks::Super::Queue::QUEUE_MONITOR_FREQ
  #    1. may be assigned any value
  #    2. but fetched value is a positive integer
  #    3. on change, restarts the queue monitor

  $Forks::Super::Queue::QUEUE_MONITOR_FREQ = 30;
  ok($Forks::Super::Queue::QUEUE_MONITOR_FREQ == 30, 
     "\$QUEUE_MONITOR_FREQ init");

  $Forks::Super::Queue::QUEUE_MONITOR_FREQ = 10;
  ok($Forks::Super::Queue::QUEUE_MONITOR_FREQ == 10, 
     "\$QUEUE_MONITOR_FREQ change");

  $Forks::Super::Queue::QUEUE_MONITOR_FREQ = -50;
  ok($Forks::Super::Queue::QUEUE_MONITOR_FREQ > 0,
     "\$QUEUE_MONITOR_FREQ is positive");
  $Forks::Super::Queue::QUEUE_MONITOR_FREQ = 30;

  ok(!defined $Forks::Super::Queue::QUEUE_MONITOR_PID,
     "\$QUEUE_MONITOR_PID not defined");

  my $start_after = 5 + Time::HiRes::gettimeofday();
  my $job = Forks::Super::Job->new({ 
				  queue_priority => 0,
				  style => 'sub',
				  sub => sub { sleep 5 },
				  start_after => $start_after });
  Forks::Super::Queue::queue_job($job);

  ok(defined $Forks::Super::Queue::QUEUE_MONITOR_PID,
     "\$QUEUE_MONITOR_PID defined after job put on queue");

  my $qmpid = $Forks::Super::Queue::QUEUE_MONITOR_PID;
  $Forks::Super::Queue::QUEUE_MONITOR_FREQ = 60;
  ok(defined $Forks::Super::Queue::QUEUE_MONITOR_PID,         ### 6 ###
     "Queue monitor still running after \$QUEUE_MONITOR_FREQ change");
  ok($Forks::Super::Queue::QUEUE_MONITOR_PID != $qmpid,
     "Queue monitor restarted after \$QUEUE_MONITOR_FREQ change");

  $qmpid = $Forks::Super::Queue::QUEUE_MONITOR_PID;

  # $Forks::Super::Queue::INHIBIT_QUEUE_MONITOR
  #    1. takes on boolean values
  #    2. on change to true, kills queue monitor

  ok($Forks::Super::Queue::INHIBIT_QUEUE_MONITOR == 0
     || $Forks::Super::Queue::INHIBIT_QUEUE_MONITOR == 1,
     "\$INHIBIT_QUEUE_MONITOR has a boolean value");

  @Forks::Super::Queue::QUEUE = ();
  $Forks::Super::Queue::INHIBIT_QUEUE_MONITOR = "";
  ok($Forks::Super::Queue::INHIBIT_QUEUE_MONITOR == 0,
     "\$INHIBIT_QUEUE_MONITOR has a boolean value");
  Forks::Super::Queue::queue_job($job);

  $qmpid = $Forks::Super::Queue::QUEUE_MONITOR_PID;
  ok(defined($qmpid), 
     "Queue monitor started when \$INHIBIT_QUEUE_MONITOR disabled");

  $Forks::Super::Queue::INHIBIT_QUEUE_MONITOR = 5;
  ok($Forks::Super::Queue::INHIBIT_QUEUE_MONITOR == 1,
     "\$INHIBIT_QUEUE_MONITOR has a boolean value");
  ok(!defined($Forks::Super::Queue::QUEUE_MONITOR_PID),
     "queue monitor disabled when \$INHIBIT_QUEUE_MONITOR enabled");

  # $Forks::Super::QUEUE_INTERRUPT
  #    0. inherits from Forks::Super::Tie::Enum
  #    1. may only be assigned from valid signal names
  #    2. on change, restarts the queue monitor

  if (0 == keys %SIG) {
    skip "\%SIG not initialized. Can't test \$Forks::Super::QUEUE_INTERRUPT",
      3;
  }

  ok(defined($SIG{$Forks::Super::QUEUE_INTERRUPT}),
     "\$QUEUE_INTERRUPT set to a valid signal name");

  my @sig = keys %SIG;

  my $qi = $Forks::Super::QUEUE_INTERRUPT;
  $Forks::Super::QUEUE_INTERRUPT = $sig[0];
  ok($Forks::Super::QUEUE_INTERRUPT eq $sig[0],
     "\$QUEUE_INTERRUPT set to $sig[0]");

  $Forks::Super::QUEUE_INTERRUPT = 'not a signal name';
  ok($Forks::Super::QUEUE_INTERRUPT eq $sig[0],
     "\$QUEUE_INTERRUPT not set to bogus signal name");


  
}  # end SKIP

waitall;
