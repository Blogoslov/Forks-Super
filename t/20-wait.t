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
ok(_isValidPid($pid));
ok($p == $pid);
ok($t <= 1);
ok($s == 512);

############################################

$pid = fork { 'sub' => sub { sleep 3; exit 3 } };
$t = time;
$p = wait;
$t = time - $t;
$s = $?;
ok(_isValidPid($pid) && $p==$pid);
ok($t >= 3);
ok($s == 768);

############################################

my %x;
$Forks::Super::MAX_PROC = 100;
for (my $i=0; $i<20; $i++) {
  $pid = fork { 'sub' => sub { my $d=int(1+6*rand); sleep $d; exit $i } };
  ok(_isValidPid($pid));
  $x{$pid} = $i;
}
$t = time;
while (0 < scalar keys %x) {
  my $p = wait;
  ok(_isValidPid($p));
  ok(defined $x{$p});
  ok($?>>8 == $x{$p});
  delete $x{$p};
}
$t = time - $t;
ok($t <= 8);
$t = time;
for (my $i=0; $i<5; $i++) {
  my $p = wait;
  ok($p == -1, "wait on nothing gives -1");
}
$t = time - $t;
ok($t <= 1);



__END__

-------------------------------------------------------

Feature:	wait function

What to test:	wait function when there is something to reap immediately
		wait function when we wait for something to reap
		wait function when there is nothing to reap
		multiple wait calls for multiple reaps

-------------------------------------------------------
