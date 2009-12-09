use Forks::Super ':test';
use Test::More tests => 94;
use strict;
use warnings;

#
# tests the Forks::Super::wait call
#

my $pid = fork { 'sub' => sub { sleep 2 ; exit 2 } };
sleep 3;
my $t = time;
my $p = wait;
$t = time - $t;
my $s = $?;
ok(isValidPid($pid), "fork was successful");
ok($p == $pid, "wait captured correct pid");
ok($t <= 1, "wait did not take much time");
ok($s == 512, "wait set exit status in \$\?");

############################################

$pid = fork { 'sub' => sub { sleep 3; exit 3 } };
$t = time;
$p = wait;
$t = time - $t;
$s = $?;
ok(isValidPid($pid) && $p==$pid, "successful fork+wait");
ok($t >= 3, "child completed");
ok($s == 768, "correct exit status captured");

############################################

my %x;
$Forks::Super::MAX_PROC = 100;
for (my $i=0; $i<20; $i++) {
  $pid = fork { 'sub' => sub { my $d=int(1+6*rand); sleep $d; exit $i } };
  ok(isValidPid($pid), "successful fork $pid");
  $x{$pid} = $i;
}
$t = Forks::Super::Time();
while (0 < scalar keys %x) {
  my $p = wait;
  ok(isValidPid($p), "waited on arbitrary pid $p");
  ok(defined $x{$p}, "return value from wait was valid pid");
  ok($?>>8 == $x{$p}, "wait returned correct exit status");
  delete $x{$p};
}
$t = Forks::Super::Time() - $t;
ok($t <= 8, "wait did not take too long ${t}s, expected <=8s");
$t = Forks::Super::Time();
for (my $i=0; $i<5; $i++) {
  my $p = wait;
  ok($p == -1, "wait on nothing gives -1");
}
$t = Forks::Super::Time() - $t;
ok($t <= 1, "no delay for wait on nothing ${t}s, expected <=1s");



__END__

-------------------------------------------------------

Feature:	wait function

What to test:	wait function when there is something to reap immediately
		wait function when we wait for something to reap
		wait function when there is nothing to reap
		multiple wait calls for multiple reaps

-------------------------------------------------------
