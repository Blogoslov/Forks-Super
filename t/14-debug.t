use Forks::Super ':test';
use Test::More tests => 8;
use strict;
use warnings;

# test global and job-specific debugging settings.
# longer PAUSE means fewer spurious _reap messages
# and smaller chance of false negative result
if ($Forks::Super::Util::DEFAULT_PAUSE < 0.5) {
    $Forks::Super::Util::DEFAULT_PAUSE = 0.5;
}

my $debug_file = "t/out/debug1-$^O-$].$$";
if (-f $debug_file) {
  unlink $debug_file;
}
if (!open($Forks::Super::Debug::DEBUG_fh, ">", $debug_file)) {
  die "$debug_file open failed $!";
}

my $fh = select Forks::Super::DEBUG;
$| = 1;
select $fh;

$Forks::Super::DEBUG = 0;
my $X;
open($X, "<", $debug_file);

END {
  close $X;
  close $Forks::Super::Debug::DEBUG_fh;
  unlink $debug_file;
}

my $pid = fork { sub => sub { sleep 2 }, timeout => 5 };
wait;
my @out1 = <$X>;
seek $X, 0, 1;
ok(@out1 == 0, "debugging off");
sleep 1;

$Forks::Super::DEBUG = 1;
$pid = fork { sub => sub { sleep 2 }, timeout => 5 };
wait;
sleep 1;

@out1 = <$X>;
seek $X, 0, 1;
ok(@out1 > 0, "debugging on");
my $out1 = scalar @out1;
sleep 1;

$pid = fork { sub => sub { sleep 2 }, timeout => 5, debug => 0 };
wait;
sleep 1;

my @out2 = <$X>;
seek $X, 0, 1;
my $out2 = scalar @out2;
ok($out2 > 0, "module debugging on");

if ($out2 >= $out1) {
  print STDERR "    Pending failure in test $0:\n";
  print STDERR "    -----------------------------\n";
  print STDERR "    full debugging:\n";
  print STDERR join "    ", "\n    ", @out1;
  print STDERR "\n    -----------------------------\n";
  print STDERR "    module debugging only:\n";
  print STDERR join "    ", "\n    ", @out2;
  print STDERR "    ------------------------------\n\n";
}

ok($out2 < $out1, "but job debugging off $out1 > $out2");
sleep 1;

$Forks::Super::DEBUG = 0;
$pid = fork { sub => sub { sleep 2 }, timeout => 5, debug => 1 };
wait;
sleep 1;

my @out3 = <$X>;
seek $X, 0, 1;
my $out3 = scalar @out3;
ok($out3 > 0, "job debugging on");
ok($out3 < $out1, "but module debugging off $out1 > $out3");
sleep 1;

$pid = fork { sub => sub { sleep 2 }, timeout => 5, debug => 1, undebug => 1 };
wait;
sleep 1;

my @out4 = <$X>;
seek $X, 0, 1;
my $out4 = scalar @out4;
ok($out4 > 0, "job debugging on");
ok($out4 < $out3, "undebug on, child debug disabled $out3 > $out4");

