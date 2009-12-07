use Forks::Super ':test';
use Test::More tests => 8;
use strict;
use warnings;

# test global and job-specific debugging settings.

open(LOCK, ">>", "t/out/.lock-t14");
flock LOCK, 2;

my $debug_file = "t/out/debug1-$^O-$].out";
if (-f $debug_file) {
  unlink $debug_file;
}
if (!open(Forks::Super::DEBUG, ">", $debug_file)) {
 #SKIP: {
 #   skip "skipping debug tests: can't open debug output file $!", 8;
 # }
  die "debug1.out open failed $!";
}

my $fh = select Forks::Super::DEBUG;
$| = 1;
select $fh;

$Forks::Super::DEBUG = 0;
my $X;
open($X, "<", $debug_file);


my $pid = fork { sub => sub { sleep 1 }, timeout => 5 };
wait;
my @out1 = <$X>;
seek $X, 0, 1;
ok(@out1 == 0, "debugging off");
sleep 1;

$Forks::Super::DEBUG = 1;
$pid = fork { sub => sub { sleep 1 }, timeout => 5 };
wait;
sleep 1;

@out1 = <$X>;
seek $X, 0, 1;
ok(@out1 > 0, "debugging on");
my $out1 = scalar @out1;
sleep 1;

$pid = fork { sub => sub { sleep 1 }, timeout => 5, debug => 0 };
wait;
sleep 1;

my @out2 = <$X>;
seek $X, 0, 1;
my $out2 = scalar @out2;
ok($out2 > 0, "module debugging on");
ok($out2 < $out1, "but job debugging off $out1 > $out2");
sleep 1;

$Forks::Super::DEBUG = 0;
$pid = fork { sub => sub { sleep 1 }, timeout => 5, debug => 1 };
wait;
sleep 1;

my @out3 = <$X>;
seek $X, 0, 1;
my $out3 = scalar @out3;
ok($out3 > 0, "job debugging on");
ok($out3 < $out1, "but module debugging off $out1 > $out3");
sleep 1;

$pid = fork { sub => sub { sleep 1 }, timeout => 5, debug => 1, undebug => 1 };
wait;
sleep 1;

my @out4 = <$X>;
seek $X, 0, 1;
my $out4 = scalar @out4;
ok($out4 > 0, "job debugging on");
ok($out4 < $out3, "undebug on, child debug disabled $out3 > $out4");

close LOCK;

