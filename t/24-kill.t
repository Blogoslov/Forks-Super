use Forks::Super ':test', MAX_PROC => 5, ON_BUSY => 'queue';
use Test::More tests => 8;
use strict;
use warnings;

# as of v0.30, the kill and kill_all functions are not very well speced out.
# these tests should pass in the current incarnation, though.

my $bgsub = sub {
  # In case process doesn't know it's supposed to exit on SIGQUIT:
  $SIG{QUIT} = sub { die "$$ received SIGQUIT\n" };
  sleep 15;
};

SKIP: {
  if ($^O eq "MSWin32" && !Forks::Super::Config::CONFIG("Win32::API")) {
    skip "kill is unsafe on MSWin32 without Win32::API", 8;
  }

  my $pid1 = fork { sub => $bgsub };
  my $pid2 = fork { sub => $bgsub };
  my $pid3 = fork { sub => $bgsub };
  my $j1 = Forks::Super::Job::get($pid1);

  ok(isValidPid($pid1) && isValidPid($pid2) && isValidPid($pid3),
     "launched $pid1,$pid2,$pid3");

  my $y = Forks::Super::kill('QUIT', $j1);
  ok($y == 1, "kill signal to $pid1 sent successfully $y==1");
  sleep 1;

  Forks::Super::Debug::_use_Carp_Always();

  my $t = Time::HiRes::gettimeofday();
  my $p = waitpid $pid1, 0, 20;
  $t = Time::HiRes::gettimeofday() - $t;
  ok($t < 6,              ### 3 ### was 3, obs 4.4,5.44 on Cygwin
     "process $pid1 took ${t}s to reap, expected fast"); 
     # [sometimes it can take a while, though]

  ok($p == $pid1, "kill signal to $p==$pid1 successful");        ### 4 ###

  my $z = Forks::Super::kill_all('TERM');
  ok($z == 2, "kill_all signal to $z==$pid2,$pid3 successful");
  sleep 1;

  waitall;

  $pid1 = fork { sub => sub { sleep 5 } };
  $pid2 = fork { sub => sub { sleep 5 } };
  $pid3 = fork { sub => sub { sleep 5 }, depend_on => $pid1 };
  $j1 = Forks::Super::Job::get($pid1);
  sleep 1;
  $y = Forks::Super::kill('INT', $pid1);
  sleep 2;
  Forks::Super::Queue::run_queue();
  ok($y == 1, "sent INT to $y==1 proc");

  # fails in 5.6; job state is still ACTIVE.
  # (fails under forked_harness, but passes as standalone?)
  ok($j1->is_complete, "killed job is complete " . $j1->{state}); ### 7 ###
  waitall;

  $y = Forks::Super::kill('INT', $pid1, $pid2, $pid3);
  ok($y == 0, "kill to complete jobs returns 0");

}  # end SKIP
