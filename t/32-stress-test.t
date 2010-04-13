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
# solaris seems to have particular trouble with this test -- the script
# often aborts
#

# $SIG_DEBUG is special flag to instruct SIGCHLD handler to record what goes on
$Forks::Super::Sigchld::SIG_DEBUG = 1;
$Forks::Super::MAX_PROC = 1000;

#my $limits_file = "t/out/limits.$^O.$]";
my $limits_file = "system-limits";

if (! -r $limits_file) {

  open LOCK, '>>', "$limits_file.lock";
  flock LOCK, 2;

  if (! -r $limits_file) {
    print STDERR "System limitations file not found. Trying to create ...\n";
    system($^X, "system-limits.PL");
  }

  close LOCK;
}

if (! -r $limits_file) {
  print STDERR "System limitations file $limits_file not found. ",
    "Can't proceed\n";
  exit 1;
}

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

	# solaris tends to barf on this test even though it passes
	# the others -- disable until we figure out why.
	# (raises SIGSYS? don't know if that is easy to trap)
	if ($^O =~ /solaris/) {
	  $nn = 0;
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
  } elsif ($^O =~ /solaris/i) {

    # solaris tends to barf on this test even when the other tests do fine.
    # disable this test until we can see what is going on in solaris.
    $nn = 0;

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
  # failure point on solaris-5.8.9 135/199
  # failure point on solaris-5.11.3 29/75
  # failure point on solaris-5.11.4 96/199
  my $pid = fork { sub => sub { sleep 5 } };
  if (!isValidPid($pid)) {
    croak "fork failed i=$i OS=$^O V=$]";
  }
  if (Forks::Super::CONFIG("Time::HiRes")) {
    Time::HiRes::sleep(0.001);
  }
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
  $fail+=100 if $start > $end;
  ok($fail == 0, "CHLD_handle history consistent " . 
     scalar @Forks::Super::CHLD_HANDLE_HISTORY . " records fail=$fail");

  $test::fail = $fail;
}
if ($test::fail > 0) {
  print STDERR "Errors in $0\n";
  print STDERR "Writing SIGCHLD handler history to\n";
  print STDERR "'t/out/sigchld.debug' for analysis.\n";
  open(D, ">", "t/out/sigchld.debug");
  print D @Forks::Super::CHLD_HANDLE_HISTORY;
  close D;
}


__END__
