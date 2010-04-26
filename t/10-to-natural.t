use Forks::Super ':test';
use POSIX ':sys_wait_h';
use Test::More tests => 15;
use strict;
use warnings;
$| = 1;

#
# test that a "natural" fork call behaves the same way
# as the Perl system fork call.
#

# verify every step of the life-cycle of a child process

my $pid = fork;
ok(defined $pid, "$$\\pid defined after fork") if $$==$Forks::Super::MAIN_PID;

if ($pid == 0) {
  sleep 2;
  exit 1;
}
ok(isValidPid($pid), "pid $pid shows child proc");
ok($$ == $Forks::Super::MAIN_PID, "parent pid $$ is current pid");
my $job = Forks::Super::Job::get($pid);
ok(defined $job, "got Forks::Super::Job object $job");
ok($job->{style} eq "natural", "natural style");
ok($job->{state} eq "ACTIVE", "active state");
my $waitpid = waitpid($pid,WNOHANG);
ok(-1 == $waitpid, "non-blocking wait succeeds");
ok(! defined $job->{status}, "no job status");
Forks::Super::pause(4);
ok($job->{state} eq "COMPLETE", "job state " . $job->{state} . "==COMPLETE");
ok(defined $job->{status}, "job status defined");
ok($? != $job->{status}, "job status not available yet");
my $p = waitpid $pid,0;
ok($job->{state} eq "REAPED", "job status REAPED after waitpid");
ok($p == $pid, "reaped correct pid");
ok($? == 256, "system status is $?, Expected 256");
ok($? == $job->{status}, "captured correct job status");

#########################################################

__END__
-------------------------------------------------------

Feature:	ordinary fork

What to test:	behavior is the same as CORE::fork()
		child process has different $$

-------------------------------------------------------
