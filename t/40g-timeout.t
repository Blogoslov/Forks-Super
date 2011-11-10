use Forks::Super ':test';
use Test::More tests => 10;
use Carp;
use strict;
use warnings;

# 
# test that spawned jobs (grandchild processes)
# also respect deadlines from the "timeout"
# and "expiration" options
#

if (${^TAINT}) {
    $ENV{PATH} = "";
    ($^X) = $^X =~ /(.*)/;
    ($ENV{HOME}) = $ENV{HOME} =~ /(.*)/;
}

SKIP: {

=begin XXXXXX workaround in v0.55

    if (!$Forks::Super::SysInfo::CONFIG{'alarm'}) {
        skip "alarm function unavailable on this system ($^O,$]), "
          . "can't test timeout feature", 6;
    }
    if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
        skip "alarm not compatible with sleep on this system ($^O,$]), "
          . "can't test timeout feature", 6;
    }

=end XXXXXX

=cut

if (!$Forks::Super::SysInfo::CONFIG{'getpgrp'}) {
    if (!($^O eq 'MSWin32' 
	  && Forks::Super::Config::CONFIG_module("Win32::Process"))) {

	skip "Skipping tests about timing out grandchildren "
	    . "because setpgrp() and TASKKILL are unavailable", 6;
    }
}




# a child process that times out should clean up after
# itself (i.e., kill off its grandchildren).
#
# This is harder to do on some systems than on others.

unlink "t/out/spawn.pids.$$";
my $t = Time::HiRes::time();

# set up a program to spawn many other processes and to run
# for about 15 seconds.
my $pid = fork { timeout => 5, 
		 cmd => [ $^X, "t/spawner-and-counter.pl",
			  "t/out/spawn.pids.$$", "3", "15" ] };
my $t2 = Time::HiRes::time();

my $p = wait;
my $t3 = Time::HiRes::time();
($t,$t2) = ($t3-$t,$t3-$t2);
my $j = Forks::Super::Job::get($pid);
my $t4 = $j->{end} - $j->{start};
okl($p == $pid && $t >= 4.5 && $t4 <= 10 && $t2 <= 10,  # was 8/9 obs 11.26
    "external prog took ${t}s ${t2}s ${t4}s, expected 5-7s");

if ($t <= 14) {
    sleep 20 - $t;
} else {
    sleep 1;
}

open(my $PIDS, "<", "t/out/spawn.pids.$$");
my @pids = <$PIDS>;
for (@pids) { s/\s+$// }
close $PIDS;
ok(@pids == 4, "spawned " . scalar @pids . " procs, Expected 4");
for (my $i=0; $i<4 && $i<@pids; $i++) {
    my ($pid_i, $file_i) = split /,/, $pids[$i];
    open(my $F_I, "<", $file_i);
    my @data_i = <$F_I>;
    close $F_I;
    my @orig_data_i = @data_i;
    pop @data_i while @data_i > 0 && $data_i[-1] !~ /\S/;
    my $last_count_i = $data_i[-1] + 0;

    # failure point, Cygwin v5.6.1
    ok($last_count_i >= 5,
       "Last count from $file_i was $last_count_i, "
       . "Expect >= 5");   ### 3-6 ###
    if ($last_count_i < 5) {
	print STDERR "File contents were:\n", @orig_data_i, "\n";
    }
    ($file_i) = $file_i =~ /(.*)/;
    if ($last_count_i > 5) {
	unlink $file_i;
    }
}
unlink "t/out/spawn.pids.$$";

waitall;
} # end SKIP

SKIP: {

=workaround 0.55 XXXXXX

    if (!$Forks::Super::SysInfo::CONFIG{'alarm'}) {
	skip "alarm function unavailable on this system ($^O,$]), "
	    . "can't test timeout feature", 4;
    }

=cut

if (!$Forks::Super::SysInfo::CONFIG{'getpgrp'}) {
    skip "setpgrp() unavailable, can't test process group manipulation", 4;
}
my ($job, $pgid, $ppgid);

# job without expiration
$ppgid = getpgrp();
my $pid = fork { sub => sub { sleep 5 } };
$job = Forks::Super::Job::get($pid);
$pgid = $job->{pgid};
my $p = waitpid -$ppgid, 0;
ok($p == $pid && $pgid == $ppgid, 
   "child pgid set to parent pgid")
    or diag("Expect waitpid output $p == pid $pid, ",
	    "pgid $pgid == ppgid $ppgid");

# job with expiration
$pid = fork { timeout => 3, sub => sub { sleep 5 } };
$job = Forks::Super::Job::get($pid);
$pgid = $job->{pgid};
ok($pgid != $ppgid, "child pgid != parent pgid with timeout");
$p = waitpid -$ppgid, 0;
ok($p == -1, "waitpid on parent pgid returns -1");
$p = waitpid -$pgid, 0;
ok($p == $pid, "waitpid on child pgid returns child pid")
    or diag("waitpid returned $p, expected $pid");
} # end SKIP

