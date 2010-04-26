use Forks::Super ':test';
use Test::More tests => 13;
use strict;
use warnings;

if ($^O eq 'MSWin32' && !Forks::Super::Config::CONFIG("Win32::API")) {
 SKIP: {
    skip "suspend/resume not supported on MSWin32", 4;
  }
  exit 0;
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
my $t = Forks::Super::Util::Time();
$j->resume;
ok($j->{state} eq "ACTIVE", "job was resumed");
waitpid $pid,0;
$t = Forks::Super::Util::Time() - $t;
ok($t >= 2.95, "\"time stopped\" while job was suspended, ${t} >= 3s");

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
$t = Forks::Super::Util::Time();
my $p = wait 5.0;
$t = Forks::Super::Util::Time() - $t;
ok($p == Forks::Super::Wait::TIMEOUT, "wait|wait times out $p==TIMEOUT");
ok($t > 4.95, "wait|wait times out ${t}s, expected ~5s");
ok($j->{state} eq 'SUSPENDED', "wait|wait does not resume job");

$Forks::Super::Wait::WAIT_ACTION_ON_SUSPENDED_JOBS = 'fail';
$t = Forks::Super::Util::Time();
$p = wait 5.0;
$t = Forks::Super::Util::Time() - $t;
ok($p == Forks::Super::Wait::ONLY_SUSPENDED_JOBS_LEFT, 
   "wait|fail returns invalid");
ok($t < 1.95, "fast fail ${t}s expected <1s");
ok($j->{state} eq 'SUSPENDED', "wait|fail does not resume job");

$Forks::Super::Wait::WAIT_ACTION_ON_SUSPENDED_JOBS = 'resume';
$t = Forks::Super::Util::Time();
$p = wait 10.0;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait|resume makes a process complete");
ok($t > 1.95 && $t < 4.5,         ### 12 ###
   "job completes before wait timeout ${t}s, expected 3-4s");
ok($j->{state} eq "REAPED", "job is complete");

#############################################################################

# XXXXXX - Forks::Super::kill + suspend/resume.

# ACTIVE + SIGSTOP --> SUSPENDED
# DEFERRED + SIGSTOP --> SUSPENDED-DEFERRED
# SUSPENDED + SIGCONT --> ACTIVE
# SUSPENDED-DEFERRED + SIGCONT -> DEFERRED or ACTIVE

# XXXXXX - MSWin32 check STOP+STOP+STOP+STOP+CONT --> ACTIVE

