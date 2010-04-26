use Forks::Super ':test';
use Test::More tests => 10;
use Carp;
use strict;
use warnings;

#
# test that jobs respect deadlines for jobs to
# complete when the jobs specify "timeout" or
# "expiration" options
#

if (!Forks::Super::CONFIG("alarm")) {
 SKIP: {
    skip "alarm function unavailable on this system ($^O,$]), "
      . "can't test timeout feature", 10;
  }
  exit 0;
}

SKIP: {
  if (!Forks::Super::Config::CONFIG("getpgrp")) {
    if (!($^O eq 'MSWin32' 
	  && Forks::Super::Config::CONFIG("Win32::Process"))) {

      skip "Skipping tests about timing out grandchildren "
	. "because setpgrp() and TASKKILL are unavailable", 6;
    }
  }

  # a child process that times out should clean up after
  # itself (i.e., kill off its grandchildren). 

  unlink "t/out/spawn.pids.$$";
  my $t = Forks::Super::Util::Time();
  my $pid = fork { timeout => 5, 
		     cmd => [ $^X, "t/spawner-and-counter.pl",
			      "t/out/spawn.pids.$$", "3", "15" ] };
  my $t2 = Forks::Super::Util::Time();
  my $p = wait;
  my $t3 = Forks::Super::Util::Time();
  ($t,$t2) = ($t3-$t,$t3-$t2);
  my $j = Forks::Super::Job::get($pid);
  my $t4 = $j->{end} - $j->{start};
  ok($p == $pid && $t >= 5 && $t4 <= 10 && $t2 <= 10,  # was 8/9 obs 9.8/9.8
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

    ok($last_count_i > 5,
       "Last count from $file_i was $last_count_i, "
       . "Expect > 5");   ### 19,20,21,22 ###
    if ($last_count_i <= 5) {
      print STDERR "File contents were:\n", @orig_data_i, "\n";
    }
    unlink $file_i if  $last_count_i > 5;
  }
  unlink "t/out/spawn.pids.$$";
  
  waitall;
}

SKIP: {
  if (!Forks::Super::Config::CONFIG("getpgrp")) {
    skip "setpgrp() unavailable, can't test process group manipulation", 4;
  }
  my ($job, $pgid, $ppgid);

  $ppgid = getpgrp();
  my $pid = fork { sub => sub { sleep 5 } };
  $job = Forks::Super::Job::get($pid);
  $pgid = $job->{pgid};
  my $p = waitpid -$ppgid, 0;
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
