use Forks::Super ':test';
use Test::More tests => 28;
use strict;
use warnings;

#
# test that jobs respect deadlines for jobs to
# complete when the jobs specify "timeout" or
# "expiration" options
#

if (!Forks::Super::CONFIG("alarm")) {
  SKIP: {
    skip "alarm func not available on this system ($^O,$]). ".
	"Skipping all tests.", 28;
  }
  exit 0;
}

my $pid = fork { 'sub' => sub { sleep 5; exit 0 }, timeout => 3 };
my $t = Forks::Super::Time();
my $p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait successful");
ok($t < 5, "Timed out in ${t}s, should have taken 3-4");
ok($? != 0, "job expired with non-zero exit status");

#######################################################

$pid = fork { 'sub' => sub { sleep 5; exit 0 }, timeout => 10 };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait successful");
ok($t < 9, "job completed before timeout");
ok($? == 0, "job completed with zero exit status");

#######################################################

$pid = fork { 'sub' => sub { sleep 5; exit 0 }, timeout => 0 };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait successful");
ok($t <= 1, "fast fail timeout=$t");
ok($? != 0, "job failed with non-zero status");

#######################################################

my $now = Forks::Super::Time();
my $future = Forks::Super::Time() + 3;
$pid = fork { 'sub' => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait successful");
ok($t < 5, "should take about 3 seconds, took $t");
ok($? != 0, "job expired with non-zero status");

#######################################################

$future = Forks::Super::Time() + 10;
$pid = fork { 'sub' => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait successful");
ok($t < 9, "job completed before expiration");
ok($? == 0, "job completed with zero exit status");

#######################################################

$future = Forks::Super::Time() - 5;
$pid = fork { 'sub' => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait succeeded");
ok($t <= 1, "expected fast fail took ${t}s");
ok($? != 0, "job expired with non-zero exit status");

#######################################################

SKIP: {
  if (!Forks::Super::CONFIG("getpgrp")) {
    skip "setpgrp() unavailable. Skipping tests about timing out grandchildren.",
      10;
  }

  unlink "t/out/spawn.pids.$$";;
  $t = Forks::Super::Time();
  $pid = fork { timeout => 5, 
		  cmd => [ $^X, "t/spawner-and-counter.pl",
			   "t/out/spawn.pids.$$", "3", "15" ] };
  $p = wait;
  $t = Forks::Super::Time() - $t;
  ok($p == $pid && $t >= 5 && $t <= 7, "external prog took ${t}s, expected 5-7s");
  if ($t < 14) {
    sleep 15 - $t;
  }
  open(PIDS, "<", "t/out/spawn.pids.$$");
  my @pids = map { s/\s+$//; $_ } <PIDS>;
  close PIDS;
  ok(@pids == 4, "spawned " . scalar @pids . " procs, expected 4");
  unlink "t/out/spawn.pids.$$";
  for (my $i=0; $i<4 && $i<@pids; $i++) {
    my ($pid_i, $file_i) = split /,/, $pids[$i];
    open(F_I, "<", $file_i);
    my @data_i = <F_I>;
    close F_I;
    pop @data_i while @data_i > 0 && $data_i[-1] !~ /\S/;
    my $last_count_i = $data_i[-1] + 0;

    ok($last_count_i > 5,
       "Last count from $file_i was $last_count_i, expect > 5");
    unlink $file_i;
  }

  waitall;
  my ($job, $pgid, $ppgid);

  $ppgid = getpgrp();
  $pid = fork { sub => sub { sleep 5 } };
  $job = Forks::Super::Job::get($pid);
  $pgid = $job->{pgid};
  $p = waitpid -$ppgid, 0;
  ok($p == $pid && $pgid == $ppgid);

  $pid = fork { timeout => 3, sub => sub { sleep 5 } };
  $job = Forks::Super::Job::get($pid);
  $pgid = $job->{pgid};
  ok($pgid != $ppgid);
  $p = waitpid -$ppgid, 0;
  ok($p == -1);
  $p = waitpid -$pgid, 0;
  ok($p == $pid);
}
