use Forks::Super ':test';
use Test::More tests => 8;
use strict;
use warnings;

# test global and job-specific debugging settings.

if (-f "t/out/debug1.out") {
  unlink "t/out/debug1.out";
}
open(Forks::Super::DEBUG, ">", "t/out/debug1.out") or die "debug1.out open failed $!";

my $fh = select Forks::Super::DEBUG;
$| = 1;
select $fh;

$Forks::Super::DEBUG = 0;
my $X;
open($X, "<", "t/out/debug1.out");


my $pid = fork { sub => sub { sleep 1 }, timeout => 5 };
wait;
my @out = <$X>;
seek $X, 0, 1;
ok(@out == 0, "debugging off");
sleep 1;

$Forks::Super::DEBUG = 1;
$pid = fork { sub => sub { sleep 1 }, timeout => 5 };
wait;


@out = <$X>;
seek $X, 0, 1;
ok(@out > 0, "debugging on");
my $out1 = scalar @out;
sleep 1;

$pid = fork { sub => sub { sleep 1 }, timeout => 5, debug => 0 };
wait;
@out = <$X>;
seek $X, 0, 1;
my $out2 = scalar @out;
ok($out2 > 0, "module debugging on");
ok($out2 < $out1, "but job debugging off $out1 > $out2");
sleep 1;

$Forks::Super::DEBUG = 0;
$pid = fork { sub => sub { sleep 1 }, timeout => 5, debug => 1 };
wait;
@out = <$X>;
seek $X, 0, 1;
my $out3 = scalar @out;
ok($out3 > 0, "job debugging on");
ok($out3 < $out1, "but module debugging off $out1 > $out3");
sleep 1;

$pid = fork { sub => sub { sleep 1 }, timeout => 5, debug => 1, undebug => 1 };
wait;
@out = <$X>;
seek $X, 0, 1;
my $out4 = scalar @out;
ok($out4 > 0, "job debugging on");
ok($out4 < $out3, "undebug on, child debug disabled $out3 > $out4");

