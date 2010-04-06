use Forks::Super ':test';
use Test::More tests => 20;
use strict;
use warnings;

#
# test that background jobs send a SIGCHLD to the parent when
# they complete and that the signal is handled by the parent.
# Jobs stay in the "COMPLETE" state until they are waited on
# with Forks::Super::wait or Forks::waitpid. Then the job changes to
# the "REAPED" status.
#

my $old_sig_chld = delete $SIG{CHLD};
$SIG{CHLD} = \&child_signal_hijacker;
*Forks::Super::handle_CHLD = *child_signal_hijacker;
$SIGNAL::TIME = Forks::Super::Util::Time();

my $_LOCK = 0;  # use same synchronization technique as F::S::Sigchld
sub child_signal_hijacker {
# $SIGNAL::TIME = Forks::Super::Util::Time() if $_[0] =~ /^C/;
  $_LOCK++;
  if ($_LOCK>1) {
    $_LOCK--;
    return;
  }

  my %complete;
  for my $cj (grep { $_->is_complete } @Forks::Super::ALL_JOBS) {
    $complete{$cj}++;
  }
  Forks::Super::Sigchld::handle_CHLD(@_);

  for my $cj (grep { $_->{state} eq "COMPLETE" } @Forks::Super::ALL_JOBS) {
    unless (delete $complete{$cj}) {
      #print "NEW COMPLETE JOB: ", $cj->toString(), "\n";
      $LAST::COMPLETE = $cj;
      $LAST::COMPLETE{$cj}++;
      $SIGNAL::TIME = Forks::Super::Util::Time();
    }
  }
  $_LOCK--;
  return;
}

my $pid = fork();
if (defined $pid && $pid == 0) {
  sleep 2;
  exit 0;
}
ok(defined $pid && isValidPid($pid), "$$\\valid pid $pid");
my $j = Forks::Super::Job::get($pid);
ok($j->{state} eq "ACTIVE", "active state");
my $t = Forks::Super::Util::Time();
sleep 6;   # sleep can be interrupted by SIGCHLD
$t = Forks::Super::Util::Time() - $t;
SKIP: {
  if ($^O eq "MSWin32") {
    Forks::Super::pause();
    skip "No interruption to sleep on Win32", 1;
  }
  if ($^O =~ /bsd/) {
    Forks::Super::pause();
    skip "No interruption to sleep on BSD?", 1;
  }
  ok($t <= 4.1, "Perl sleep interrupted by CHLD signal ${t}s");
}
ok($j->{state} eq "COMPLETE", "job state is COMPLETE");
SKIP: {
  skip "No implicit SIGCHLD handling on Win32", 3 if $^O eq "MSWin32";

  # XXXXXX - pass test (1) and fail test (2) would be ok
  ok(defined $LAST::COMPLETE{$j}, 
     "job caught in SIGCHLD handler/$j/" . $j->{pid}); ### 5 ###
  ok($LAST::COMPLETE eq $j, 
     "job caught in SIGCHLD handler/$LAST::COMPLETE/"
    . $LAST::COMPLETE->{pid});                         ### 6 ###
  my $tt = $SIGNAL::TIME - $j->{end};
  ok(abs($tt) < 2, "short delay ${tt}s in SIGCHLD HANDLER expected <2s");
}
sleep 1;
my $p = wait;
ok($pid == $p, "wait reaped correct process");
ok($j->{state} eq "REAPED", "reaped process has REAPED state");
ok($j->{reaped} - $j->{end} > 0, "reap occurred after job completed");
#print $j->toString();
%LAST::COMPLETE = ();

#######################################################

# try  Forks::Super::pause  for uninterruptible sleep

$pid = fork();
if (defined $pid && $pid == 0) {
  sleep 2;
  exit 0;
}
ok(defined $pid && isValidPid($pid), "valid pid $pid");
$j = Forks::Super::Job::get($pid);
ok($j->{state} eq "ACTIVE", "active state");
$t = Forks::Super::Util::Time();
Forks::Super::pause(6);   # ACK! sleep can be interrupted by CHLD signal!
$t = Forks::Super::Util::Time() - $t;
ok($t > 5.7 && $t < 7.75,                           ### 13 ### was 7.1 obs 7.10
   "Forks::Super::pause(6) took ${t}s expected 6");
ok($j->{state} eq "COMPLETE", "complete state");
SKIP: {
  skip "No implicit SIGCHLD handling on Win32", 3 if $^O eq "MSWin32";

  # XXXXXX pass test (1) and fail test (2) would be ok
  ok(defined $LAST::COMPLETE{$j}, 
     "job in SIGCHLD handler/$j/" . $j->{pid});    ### 15 ###
  ok($LAST::COMPLETE eq $j,
     "job in SIGCHLD handler/$LAST::COMPLETE/"
     . $LAST::COMPLETE->{pid});                    ### 16 ###
  my $tt = $SIGNAL::TIME - $j->{end};
  ok(abs($tt) < 2, "short delay ${tt}s in SIGCHLD handler, expected <2s");
}
$p = wait;
ok($pid == $p, "wait reaped correct job");
ok($j->{state} eq "REAPED", "job state changed to REAPED in wait");
my $tt = $j->{reaped} - $j->{end};
ok($tt > 1, 
   "reaped at $j->{reaped}, ended at $j->{end} ${tt}s expected >1s");
if ($tt <= 1) {
  print STDERR "Job created at $j->{created}\n";
  print STDERR "Job started at $j->{start}\n";
  print STDERR "Job ended at $j->{end}\n";
  print STDERR "Job reaped at $j->{reaped}\n";
}
