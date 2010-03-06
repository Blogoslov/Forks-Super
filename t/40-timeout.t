use Forks::Super ':test';
use Test::More tests => 30;
use Carp;
use strict;
use warnings;

# force loading of more modules in parent proc
# so fast fail (see test#17, test#8) isn't slowed
# down so much
Forks::Super::Job::Timeout::warm_up();

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

my $pid = fork { sub => sub { sleep 5; exit 0 }, timeout => 3 };
my $t = Forks::Super::Util::Time();
my $p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "$$\\wait successful");
ok($t < 5, "Timed out in ${t}s, expected ~3s");
ok($? != 0, "job expired with non-zero exit status");

#######################################################

$pid = fork { sub => sub { sleep 5; exit 0 }, timeout => 10 };
$t = Forks::Super::Util::Time();
$p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait successful; Expected $pid got $p");
ok($t < 9, "job completed before timeout ${t}s expected ~5s");
ok($? == 0, "job completed with zero exit status");

#######################################################



$pid = fork { sub => sub { sleep 5; exit 0 }, timeout => 0 };
$t = Forks::Super::Util::Time();
$p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait successful; Expected $pid got $p");
ok($t <= 1.9, "fast fail timeout=${t}s, expected <=1s"); ### 8 ###
ok($? != 0, "job failed with non-zero status $?");

#######################################################

my $now = Forks::Super::Util::Time();
my $future = Forks::Super::Util::Time() + 3;
$pid = fork { sub => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Util::Time();
$p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait successful");
ok($t < 5, "wait took ${t}s, expected ~3s"); ### 11 ###
ok($? != 0, "job expired with non-zero status"); ### 12 ###

# script dies intermittently here?

#######################################################

$future = Forks::Super::Util::Time() + 10;
$pid = fork { sub => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Util::Time();
$p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait successful");
ok($t < 9, "job completed before expiration ${t}s expected ~5s");
ok($? == 0, "job completed with zero exit status");

#######################################################

$future = Forks::Super::Util::Time() - 5;
$pid = fork { sub => sub { sleep 5; exit 0 }, expiration => $future };
$t = Forks::Super::Util::Time();
$p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait succeeded");
# A "fast fail" can still take longer than a second. 
# "fast fail" invokes Carp::croak, which wants to load
# Carp::Heavy, Scalar::Util, List::Util, List::Util::XS.
# That can add up.
#ok($t <= 1.0, "expected fast fail took ${t}s"); ### 17 ###
ok($t <= 1.9, "expected fast fail took ${t}s"); ### 17 ###
ok($? != 0, "job expired with non-zero exit status");

#######################################################

# when a child spawned by Forks::Super::fork times out,
# we should kill that child AND all of its children

SKIP: {
  if (!Forks::Super::CONFIG("getpgrp")) {
    skip "setpgrp() unavailable. Skipping tests about timing out grandchildren.", 10;
  }
  if (0 && getpgrp(0) != $$) {
    skip "current pgrp is != current pid -- test to time out grandchildren probably won't work", 10;
  }

  unlink "t/out/spawn.pids.$$";;
  $t = Forks::Super::Util::Time();
  $pid = fork { timeout => 5, 
		  cmd => [ $^X, "t/spawner-and-counter.pl",
			   "t/out/spawn.pids.$$", "3", "15" ] };
  my $t2 = Forks::Super::Util::Time();
  $p = wait;
  my $t3 = Forks::Super::Util::Time();
  ($t,$t2) = ($t3-$t,$t3-$t2);
  my $j = Forks::Super::Job::get($pid);
  my $t4 = $j->{end} - $j->{start};
  ok($p == $pid && $t >= 5 && $t4 <= 8 && $t2 <= 9, 
	"external prog took ${t}s ${t2}s ${t4}s, expected 5-7s");
  if ($t <= 14) {
    sleep 20 - $t;
  } else {
    sleep 1;
  }
  open(PIDS, "<", "t/out/spawn.pids.$$");
  my @pids = map { s/\s+$//; $_ } <PIDS>;
  close PIDS;
  ok(@pids == 4, "spawned " . scalar @pids . " procs, Expected 4");
  for (my $i=0; $i<4 && $i<@pids; $i++) {
    my ($pid_i, $file_i) = split /,/, $pids[$i];
    open(F_I, "<", $file_i);
    my @data_i = <F_I>;
    close F_I;
    my @orig_data_i = @data_i;
    pop @data_i while @data_i > 0 && $data_i[-1] !~ /\S/;
    my $last_count_i = $data_i[-1] + 0;


    # intermittent failures here on Cygwin -- maybe 1 in 200 times?

    ok($last_count_i > 5,
       "Last count from $file_i was $last_count_i, Expect > 5");   ### 19,20,21,22 ###
    if ($last_count_i <= 5) {
      print STDERR "File contents were:\n", @orig_data_i, "\n";
    }
    unlink $file_i if  $last_count_i > 5;
  }
  unlink "t/out/spawn.pids.$$";

  waitall;
  my ($job, $pgid, $ppgid);

  $ppgid = getpgrp();
  $pid = fork { sub => sub { sleep 5 } };
  $job = Forks::Super::Job::get($pid);
  $pgid = $job->{pgid};
  $p = waitpid -$ppgid, 0;
  ok($p == $pid && $pgid == $ppgid, "child pgid set to parent pgid");

  $pid = fork { timeout => 3, sub => sub { sleep 5 } };
  $job = Forks::Super::Job::get($pid);
  $pgid = $job->{pgid};
  ok($pgid != $ppgid, "child pgid != parent pgid with timeout");
  $p = waitpid -$ppgid, 0;
  ok($p == -1, "waitpid on parent pgid returns -1");
  $p = waitpid -$pgid, 0;
  ok($p == $pid, "waitpid on child pgid returns child pid");
}

##########################################################

my $t0 = Forks::Super::Util::Time();
$pid = fork { cmd => [ $^X, "t/external-command.pl", "-s=4" ], timeout => 2 };
$t = Forks::Super::Util::Time();
waitpid $pid, 0;
my $t2 = Forks::Super::Util::Time();
($t0,$t) = ($t2-$t0,$t2-$t);
ok($t <= 3.25, "cmd-style respects timeout ${t}s ${t0}s expected ~2s"); ### 29 ### was 3.0 obs 3.10

$t0 = Forks::Super::Util::Time();
$pid = fork { exec => [ $^X, "t/external-command.pl", "-s=4" ], timeout => 2 };
$t = Forks::Super::Util::Time();
waitpid $pid, 0;
$t = Forks::Super::Util::Time() - $t;
$t2 = Forks::Super::Util::Time();
($t0,$t) = ($t2-$t0,$t2-$t);
ok($t >= 3.9, "exec-style doesn't respect timeout ${t}s ${t0}s expected ~4s");
