use Forks::Super ':test';
use Test::More tests => 17;
use strict;
use warnings;

SKIP: {
  if ($^O eq 'MSWin32' && !Forks::Super::Config::CONFIG_module("Win32::API")) {
    skip "suspend/resume not supported on MSWin32", 13;
  }

my $pid = fork {
  sub => sub {
    for (my $i=0; $i<5; $i++) {
      sleep 1;
    }
  } };

my $j = Forks::Super::Job::get($pid);
ok(isValidPid($pid) && $j->{state} eq "ACTIVE", "$$\\created $pid");
sleep 1;
$j->suspend;
ok($j->{state} eq "SUSPENDED", "job was suspended");
sleep 5;
my $t = Time::HiRes::gettimeofday();
$j->resume;
ok($j->{state} eq "ACTIVE", "job was resumed");
waitpid $pid,0;
$t = Time::HiRes::gettimeofday() - $t;
ok($t > 2.0, "\"time stopped\" while job was suspended, ${t} >= 3s");

#############################################################################

# to test:
# if only suspended jobs are left:
# waitpid|action=wait runs indefinitely
# waitpid|action=fail returns Forks::Super::Wait::ONLY_SUSPENDED_JOBS_LEFT
# waitpid|action=resume restarts the job

$pid = fork { sub => sub { sleep 1 for (1..4) } };
$j = Forks::Super::Job::get($pid);
sleep 1;
$j->suspend;

$Forks::Super::Wait::WAIT_ACTION_ON_SUSPENDED_JOBS = 'wait';
$t = Time::HiRes::gettimeofday();
my $p = wait 5.0;
$t = Time::HiRes::gettimeofday() - $t;
ok($p == &Forks::Super::Wait::TIMEOUT, "wait|wait times out $p==TIMEOUT");
ok($t > 4.95, "wait|wait times out ${t}s, expected ~5s");
ok($j->{state} eq 'SUSPENDED', "wait|wait does not resume job");

$Forks::Super::Wait::WAIT_ACTION_ON_SUSPENDED_JOBS = 'fail';
$t = Time::HiRes::gettimeofday();
$p = wait 5.0;
$t = Time::HiRes::gettimeofday() - $t;
ok($p == &Forks::Super::Wait::ONLY_SUSPENDED_JOBS_LEFT, 
   "wait|fail returns invalid");
ok($t < 1.95, "fast fail ${t}s expected <1s");
ok($j->{state} eq 'SUSPENDED', "wait|fail does not resume job");

$Forks::Super::Wait::WAIT_ACTION_ON_SUSPENDED_JOBS = 'resume';
$t = Time::HiRes::gettimeofday();
$p = wait 10.0;
$t = Time::HiRes::gettimeofday() - $t;
ok($p == $pid, "wait|resume makes a process complete");
ok($t > 1.95 && $t < 9,         ### 12 ###
   "job completes before wait timeout ${t}s, expected 3-4s");
ok($j->{state} eq "REAPED", "job is complete");

##################################################################

# if you suspend a job more than once, and then resume it,
# it should resume. In the basic Windows API, you'd need to 
# call resume more than once, too.

$pid = fork { sub => sub { sleep 1 for (1..4) } };
$j = Forks::Super::Job::get($pid);
sleep 1;
ok($j->{state} eq 'ACTIVE', "created bg job, currently active");
$j->suspend;
ok($j->{state} eq 'SUSPENDED', "suspended bg job successfully");
$j->suspend;  # re-suspending a job generates a warning.
$j->suspend;
$j->suspend;
$j->suspend;
ok($j->{state} eq 'SUSPENDED', "multiply-suspended bg job successfully");
sleep 1;
$j->resume;
ok($j->{state} eq 'ACTIVE', "single resume reactivated bg job");
waitall;



}  # end SKIP

#############################################################################

# ACTIVE + SIGSTOP --> SUSPENDED
# DEFERRED + SIGSTOP --> SUSPENDED-DEFERRED
# SUSPENDED + SIGCONT --> ACTIVE
# SUSPENDED-DEFERRED + SIGCONT -> DEFERRED or ACTIVE

# XXXXXX - MSWin32 check STOP+STOP+STOP+STOP+CONT --> ACTIVE
