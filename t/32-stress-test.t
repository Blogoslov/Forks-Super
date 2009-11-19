use Forks::Super ':test';
use Test::More tests => 301;
use Carp;
use strict;
use warnings;

#
# arrange for many jobs to finish at about the same time.
# Is the signal handler able to handle all the SIGCHLDs and reap all the jobs on time?
# If not, do we invoke the signal handler manually and reap the
# unhandled jobs in a timely way?
# 
 


$Forks::Super::SIG_DEBUG = 1;
$Forks::Super::MAX_PROC = 1000;

my $nn = 150;  # cygwin chokes if $nn>196
SKIP: {
  if ($^O eq "MSWin32") {
    $nn = 60;
    skip "Max 64 proc on Win32, can only do 121 tests", 301-121;
  }
}
for (my $i=0; $i<$nn; $i++) {
  my $pid = fork { 'sub' => sub { sleep 5 } };
  croak "fork failed i=$i" if !_isValidPid($pid);
}

for (my $i=0; $i<$nn; $i++) {
  &check_CHLD_handle_history_for_interleaving;
  my $p = wait;
  ok(_isValidPid($p), "reaped $p");
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
  ok($fail == 0, "CHLD_handle history consistent " . scalar @Forks::Super::CHLD_HANDLE_HISTORY . " records");
}


__END__
-------------------------------------------------------

Feature:	CHLD signal handler

What to test:	Receives signal when children complete
		Changes state to COMPLETE
		Can handle children completing at same time
		See what happens when signal interrupts long sleep call

-------------------------------------------------------

