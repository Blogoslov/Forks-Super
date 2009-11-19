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
ok(defined $pid, "pid defined after fork") if $$==$Forks::Super::MAIN_PID;

if ($pid == 0) {
  sleep 2;
  Forks::Super::child_exit 1;
}
ok(_isValidPid($pid), "pid $pid shows child proc");
ok($$ == $Forks::Super::MAIN_PID, "parent pid $$ is current pid");
my $job = Forks::Super::Job::_get($pid);
ok(defined $job, "got Forks::Super::Job object $job");
ok($job->{style} eq "natural", "natural style");
ok($job->{state} eq "ACTIVE", "active state");
my $waitpid = waitpid($pid,WNOHANG);
ok(-1 == $waitpid, "non-blocking wait succeeds");
ok(! defined $job->{status}, "no job status");
Forks::Super::pause(3);
ok($job->{state} eq "COMPLETE");
ok(defined $job->{status});
ok($? != $job->{status});
my $p = waitpid $pid,0;
ok($job->{state} eq "REAPED");
ok($p == $pid);
ok($? == 256);
ok($? == $job->{status});

__END__
-------------------------------------------------------

Feature:	ordinary fork

What to test:	behavior is the same as CORE::fork()
		child process has different $$

-------------------------------------------------------
