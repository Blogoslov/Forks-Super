use Forks::Super ':test';
use Forks::Super::SysInfo;
use Test::More tests => 301;
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


ok($Forks::Super::SysInfo::SYSTEM eq $^O,
   "Forks::Super::SysInfo configured for $Forks::Super::SysInfo::SYSTEM==$^O");
ok($Forks::Super::SysInfo::PERL_VERSION <= $],
   "Forks::Super::SysInfo configured for "
   . "$Forks::Super::SysInfo::PERL_VERSION<=$]");


my $NN = 149;
my $nn = $NN;
SKIP: {
  $nn = int(0.85 * $Forks::Super::SysInfo::MAX_FORK) || 5;
  $nn = $NN if $nn > $NN;

  # solaris tends to barf on this test even though it passes
  # the others -- disable until we figure out why.
  # (raises SIGSYS? don't know if that is easy to trap)
  if ($^O =~ /solaris/) {
    $nn = 0;
  }

  if ($nn < $NN) {
    skip "Max ~$nn proc on $^O v$], can only do ".((2*$nn)+1)." tests", 
      2*($NN-$nn);
  }
}


print "\$nn is $nn $NN\n";

for (my $i=0; $i<$nn; $i++) {
  # failure point on some systems: 
  #    Maximal count of pending signals (nnn) exceeded

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
