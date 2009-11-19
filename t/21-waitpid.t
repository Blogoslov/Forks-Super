use Forks::Super ':test';
use POSIX ':sys_wait_h';
use Test::More tests => 143;
use strict;
use warnings;
alarm 90;$SIG{ALRM}=sub{die "Timeout\n"};

#
# tests the Forks::Super::waitpid call.
#


my $pid = fork { 'sub' => sub { sleep 2 ; exit 2 } };
sleep 3;
my $t = time;
my $p = waitpid $pid, WNOHANG;
$t = time - $t;
my $s = $?;
ok(_isValidPid($pid));
ok($p == $pid, "waitpid on $pid returns $p");
ok($t <= 1);
ok($s == 512);

############################################

$pid = fork { 'sub' => sub { sleep 3; exit 3 } };
ok(_isValidPid($pid));
$t = time;
$p = waitpid $pid,WNOHANG;
ok($p == -1);
ok(-1 == waitpid ($pid + 10, WNOHANG), "return -1 for invalid target");
ok(-1 == waitpid ($pid + 10, 0), "fast return -1 for invalid target");
$t = time - $t;
ok($t <= 1, "fast return");
$t = time;
$p = waitpid $pid, 0;
$t = time - $t;
$s = $?;
ok($p==$pid);
ok($t >= 3, "blocked return");
ok($s == 768);

############################################

my %x;
$Forks::Super::MAX_PROC = 100;
for (my $i=0; $i<20; $i++) {
  my $pid = fork { 'sub' => sub { my $d=int(2+8*rand); sleep $d; exit $i } };
  ok(_isValidPid($pid), "Launched $pid");
  $x{$pid} = $i;
}
$t = time;
while (0 < scalar keys %x) {

  my $p;
  my $pid = (keys %x)[rand() * scalar keys %x];
  if (defined $x{$pid}) {
    if (rand() > 0.5) {
      $p = waitpid $pid, 0;
    } else {
      $p = waitpid $pid, WNOHANG;
    }
    if (_isValidPid($p)) {
      ok($p == $pid, "Reaped $p");
      ok($? >> 8 == $x{$p}, "$p correct exit code $x{$p}");
      delete $x{$p};
    }
  } else {
    # warn "pid $pid invalid --- trying again";
  }
}

$t = time - $t;
ok($t >= 6 && $t <= 10);
$t = time;

for (my $i=0; $i<5; $i++) {
  my $p = waitpid -1, 0;
  ok($p == -1, "wait on nothing gives -1, $p");
}
$t = time - $t;

ok($t <= 1);

############################################

# waitpid 0 or -1 ?
# waitpid -t  for valid/invalid  pgid.

%x = ();
for (my $i=0; $i<20; $i++) {

  # ha ha ha. When you fork, the child inherits the current seed
  # of the random number generator, so every child will produce
  # the same random sequence. Unless you srand it yourself.

  my $pid = fork { 'sub' => sub { srand();
				  my $d=int(2+8*rand);
				  sleep $d; exit $i } };
  ok(_isValidPid($pid), "Launched $pid");
  $x{$pid} = $i;
}

$t = time;
SKIP: {
  skip "Can't test waitpid on pgid on Win32", 44 if $^O eq "MSWin32";

  my $pgid = getpgrp();
  my $bogus_pgid = $pgid + 175;
  ok(-1 == waitpid (-$bogus_pgid, 0), "bogus pgid");
  ok(-1 == waitpid (-$bogus_pgid, WNOHANG), "bogus pgid");
  ok(time - $t <= 1, "fast return wait on bogus pgid");

  while (0 < scalar keys %x) {

    my $p;
    my $z = rand();
    if ($z > 0.75) {
      $p = waitpid 0, WNOHANG;
    } elsif ($z > 0.5) {
      $p = waitpid -$pgid, WNOHANG; 
    } elsif ($z > 0.25) {
      $p = waitpid 0, 0;
    } else {
      $p = waitpid -$pgid, 0;
    }
    if ($p == -1 && $z <= 0.5) {
      ok(0, "waitpid did not block $z");
    } elsif (defined $x{$p}) {
      ok(_isValidPid($p), "Reaped $p");
      ok($? >> 8 == $x{$p}, "$p correct exit code $x{$p}");
      delete $x{$p};
    } else {
      # warn "pid $pid invalid --- trying again\n"; # nothing to be alarmed about
    }
  }

  $t = time - $t;
  ok($t >= 7 && $t <= 11, "Took $t s to reap all. Should take about 7-11s");
}

__END__
-------------------------------------------------------

Feature:	waitpid function

What to test:	waitpid on completed process
		waitpid on active process
			with and without WNOHANG
		waitpid -1 to reap any process
			with and without WNOHAND
		*waitpid 0 to reap something in current pgid
		*waitpid -X to reap something in pgid X

-------------------------------------------------------
