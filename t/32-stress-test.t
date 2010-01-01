use Forks::Super ':test';
use Test::More tests => 299;
use Carp;
use strict;
use warnings;

#
# arrange for many jobs to finish at about the same time.
# Is the signal handler able to handle all the SIGCHLDs and reap all the 
# jobs on time? If not, do we invoke the signal handler manually and reap the
# unhandled jobs in a timely way?
# 

#
# On Cygwin, this test sometimes hangs for exactly five minutes.
# See the note in  find-limits.pl
#
 

# $SIG_DEBUG is special flag to instruct SIGCHLD handler to record what goes on
$Forks::Super::SIG_DEBUG = 1;
$Forks::Super::MAX_PROC = 1000;

# find-limits.pl call moved to 00--pretest.t
my $limits_file = "t/out/limits.$^O.$]";

my $NN = 149;
my $nn = $NN;
SKIP: {
  if (-f $limits_file) {
    open(L, "<", $limits_file);
    while (<L>) {
      if (/maxfork:(\d+)/) {
	$nn = $1;
	print STDERR "$^O-$] can apparently support $nn simultaneous ",
		"background procs\n";
	$nn = int(0.75 * $nn);
	if ($nn > $NN) {
	  $nn = $NN;
	}
	if ($^O =~ /bsd/i && $nn > 110) {
	  $nn = 110;
	}
      }
    }
    close L;
  } elsif ($^O eq "MSWin32") {
    $nn = 60;
    $nn = 50 if $] le "5.006999";

    # perl 5.8 can handle ~60 simultaneous Windows threads on my system,
    # but perl 5.6 looks like it can only take about 50

  } elsif ($^O =~ /openbsd/) {
    $nn = 48;
  } elsif ($^O =~ /solaris/) {
    $nn = 140;
  } elsif ($^O =~ /darwin/) {
    $nn = 80;
  }
  if ($nn < $NN) {
    skip "Max ~$nn proc on $^O v$], can only do ".((2*$nn)+1)." tests", 
      2*($NN-$nn);
  }
}

for (my $i=0; $i<$nn; $i++) {
  # failure point on some systems: Maximal count of pending signals (nnn) exceeded
  my $pid = fork { 'sub' => sub { sleep 5 } };
  croak "fork failed i=$i OS=$^O V=$]" if !isValidPid($pid);
}

for (my $i=0; $i<$nn; $i++) {
  &check_CHLD_handle_history_for_interleaving;
  my $p = wait;
  ok(isValidPid($p), "reaped $p");
}
#print @Forks::Super::CHLD_HANDLE_HISTORY;
my $p = wait;
ok($p == -1, "Nothing to reap");


sub check_CHLD_handle_history_for_interleaving {
  my $start = 0;
  my $end = 0;
  my $fail = 0;
  foreach my $h (@Forks::Super::CHLD_HANDLE_HISTORY) {
    $start++ if $h =~ /start/;
    $end++ if $h =~ /end/;
    if ($start-$end > 1) {
      $fail++;
    }
  }
  $fail++ if $start > $end;
  ok($fail == 0, "CHLD_handle history consistent " . 
     scalar @Forks::Super::CHLD_HANDLE_HISTORY . " records");
}


__END__
-------------------------------------------------------

Feature:	CHLD signal handler

What to test:	Receives signal when children complete
		Changes state to COMPLETE
		Can handle children completing at same time
		See what happens when signal interrupts long sleep call

-------------------------------------------------------

