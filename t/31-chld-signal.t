use Forks::Super ':test';
use Test::More tests => 18;
use strict;
use warnings;

#
# test that background jobs send a SIGCHLD to the parent when
# they complete and that the signal is handled by the parent.
# Jobs stay in the "COMPLETE" state until they are waited on
# with Forks::Super::wait or Forks::waitpid. Then the job changes to
# the "REAPED" status.
#

sub child_signal_hijacker {
  my %complete;

  $SIGNAL::TIME = time;
  for my $cj (grep { $_->{state} eq "COMPLETE" } @Forks::Super::ALL_JOBS) {
    $complete{$cj}++;
  }
  Forks::Super::handle_CHLD(@_);
  for my $cj (grep { $_->{state} eq "COMPLETE" } @Forks::Super::ALL_JOBS) {
    unless (delete $complete{$cj}) {
      #print "NEW COMPLETE JOB: ", $cj->toString(), "\n";
      $LAST::COMPLETE = $cj;
    }
  }
}

my $old_sig_chld = delete $SIG{CHLD};
$SIG{CHLD} = \&child_signal_hijacker;


my $pid = fork();
if (defined $pid && $pid == 0) {
  sleep 3;
  exit 0;
}
ok(defined $pid && isValidPid($pid), "valid pid $pid");
my $j = Forks::Super::Job::get($pid);
ok($j->{state} eq "ACTIVE", "active state");
my $t = time;
sleep 6;   # ACK! sleep can be interrupted by CHLD signal!
$t = time - $t;
SKIP: {
  if ($^O eq "MSWin32") {
    Forks::Super::pause();
    skip "No interruption to sleep on Win32", 1;
  }
  ok($t <= 4, "Perl sleep interrupted by CHLD signal");
}
ok($j->{state} eq "COMPLETE", "job state is COMPLETE");
SKIP: {
  skip "No implicit SIGCHLD handling on Win32", 2 if $^O eq "MSWin32";
  ok($LAST::COMPLETE eq $j, "job caught in SIGCHLD handler");
  ok(abs($SIGNAL::TIME - $j->{end}) < 2, "short delay in SIGCHLD handler");
}
sleep 1;
my $p = wait;
ok($pid == $p, "wait reaped correct process");
ok($j->{state} eq "REAPED", "reaped process has REAPED state");
ok($j->{reaped} - $j->{end} > 0, "reap occurred after job completed");
#print $j->toString();

#######################################################

# try  Forks::Super::pause  for uninterruptible sleep

$pid = fork();
if (defined $pid && $pid == 0) {
  sleep 3;
  exit 0;
}
ok(defined $pid && isValidPid($pid), "valid pid $pid");
$j = Forks::Super::Job::get($pid);
ok($j->{state} eq "ACTIVE", "active state");
$t = Forks::Super::Time();  # uses Time::HiRes if available, otherwise same as time
Forks::Super::pause(6);   # ACK! sleep can be interrupted by CHLD signal!
$t = Forks::Super::Time() - $t;
ok($t > 5.7, "Forks::Super::pause(6) took ${t}s expected 6");
ok($j->{state} eq "COMPLETE", "complete state");
SKIP: {
  skip "No implicit SIGCHLD handling on Win32", 2 if $^O eq "MSWin32";
  ok($LAST::COMPLETE eq $j, "job in SIGCHLD handler");
  ok(abs($SIGNAL::TIME - $j->{end}) < 2, "short delay in SIGCHLD handler");
}
$p = wait;
ok($pid == $p, "wait reaped correct job");
ok($j->{state} eq "REAPED", "job state changed to REAPED in wait");
ok($j->{reaped} - $j->{end} > 1,
	"reaped at $j->{reaped}, ended at $j->{end}");
#print $j->toString();


__END__
-------------------------------------------------------

Feature:	CHLD signal handler

What to test:	Receives signal when children complete
		Changes state to COMPLETE
		Can handle children completing at same time
		See what happens when signal interrupts long sleep call

-------------------------------------------------------
