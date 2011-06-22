use Sys::CpuAffinity;
use Test::More tests => 14;
use strict;
use warnings;

my $ntests = 14;

my $n = Sys::CpuAffinity::getNumCpus();
ok($n > 0, "discovered $n processors");

if ($^O =~ /darwin/i || $^O =~ /MacOS/i) {
 SKIP: {
    skip "get/set affinity not supported on MacOS", $ntests - 1;
  }
  exit 0;
}


if ($n <= 1) {
 SKIP: {
    if ($n == 1) {
      skip "can't test affinity on single cpu system", $ntests - 1;
    } else {
      skip "can't test: can't detect number of cpus", $ntests - 1;
    }
  }
  exit 0;
}

my $y = Sys::CpuAffinity::getAffinity($$) || 0;
ok($y > 0 && $y < 2**$n, "got current process affinity $y");

my $simpleMask = getSimpleMask($n);
my $clearMask  = getUnbindMask($n);

my $complexMask = getComplexMask($n);

# set and clear simple mask (bind to one processor)

my $z = Sys::CpuAffinity::setAffinity($$, $simpleMask);
ok($z != 0, "simple setCpuAffinity returned non-zero");

my $y1 = Sys::CpuAffinity::getAffinity($$) || 0;
ok($y1 == $simpleMask, 
   "setCpuAffinity set affinity to $y1 == $simpleMask != $y");

$z = Sys::CpuAffinity::setAffinity($$, $clearMask);
ok($z != 0, "clear simple setCpuAffinity returned non-zero");

my $y2 = Sys::CpuAffinity::getAffinity($$) || 0;
ok($y2 + 1 == 2**$n, "bind to all processors successful $y2 == ".(2**$n)."-1");

# set and clear complex mask (more than one processor, but less than all)

SKIP: {
  if ($n < 3) {
    Sys::CpuAffinity::setAffinity($$, $simpleMask);
    skip "complex mask test. Need >2 cpus to form complex mask", 2;
  }

  if ($^O =~ /solaris/) {
    skip "complex mask test. Processes in $^O may only bind to "
      . "1 or all processors", 2;
  }


  $z = Sys::CpuAffinity::setAffinity($$, $complexMask);
  ok($z != 0, "complex setCpuAffinity returned non-zero");

  my $y3 = Sys::CpuAffinity::getAffinity($$) || 0;
  ok($y3 == $complexMask, 
     "setCpuAffinity set affinity to $y3 == "
     . (sprintf "0x%x", $complexMask) . " != $y2");
}

$z = Sys::CpuAffinity::setAffinity($$, -1);
ok($z != 0, "setAffinity(-1) returned non-zero");

my $y4 = Sys::CpuAffinity::getAffinity($$) || 0;
ok($y4+1 == 2**$n, "setAffinity(-1) binds to all processors");



{
  # passing invalid arguments should fail.

  my $a = Sys::CpuAffinity::getAffinity(173551) || '';
  my $b = Sys::CpuAffinity::setAffinity(173551, -1) || '';
  my $c = Sys::CpuAffinity::getAffinity(173551) || '';
  my $d = Sys::CpuAffinity::setAffinity(-173551, 1) || '';
  my $e = Sys::CpuAffinity::getAffinity(-173551) || '';
  my $f = Sys::CpuAffinity::setAffinity($$, 0) || '';
  my $g = Sys::CpuAffinity::setAffinity($$, 2 ** $n) || '';
  ok(!($a||$b||$c||$d||$e||$f||$g),
     "passing invalid args to getAffinity, setAffinity fails")
    or diag("$a / $b / $c / $d / $e / $f / $g");
}

##################################################################

# On Windows (but not Cygwin), get/set affinity for a child process
# is different than for the parent process.
my $f = "ipc.$$";
unlink $f;
my $pid = CORE::fork();
if (defined($pid) && $pid == 0) {

  open F, '>', $f;
  my $y3 = Sys::CpuAffinity::getAffinity($$) || 0;
  print F "getAffinity:$y3\n";

  # solaris can only bind a process to one processor
  my $r3 = $^O =~ /solaris/i
	? getSimpleMask($n)
	: getComplexMask($n);

  print F "targetAffinity:$r3\n";
  my $z3 = Sys::CpuAffinity::setAffinity($$, $r3);
  print F "setAffinity:$z3\n";

  my $y4 = Sys::CpuAffinity::getAffinity($$) || 0;
  print F "getAffinity2:$y4\n";
  close F;

  exit 0;
}

CORE::wait;

if ($ENV{DEBUG}) {
  open F, '<', $f;
  print <F>;
  close F;
}

open F, '<', $f;
my $g = <F>;
my ($y3) = $g =~ /getAffinity:(\d+)/;
ok(defined($y3) && $y3 > 0 && $y3 < (2**$n), 
   "got pseudo-proc affinity $y3")
  or diag("\$y3=$y3, child output [1] was: $g");

$g = <F>;
my ($r3) = $g =~ /targetAffinity:(\d+)/;
$g = <F>;
my ($z3) = $g =~ /setAffinity:(\d+)/;
ok(defined($r3) && defined($z3) && $z3 != 0,
   "set pseudo-proc affinity non-zero result $z3")
  or diag(defined($r3),"/",defined($z3),"/<",$z3,
	  ">!=0,\nchild output [2] was $g");

$g = <F>;
close F;
unlink $f;

($y4) = $g =~ /getAffinity2:(\d+)/;
ok(defined($y4) && $y4 == $r3,
   "set pseudo-proc affinity to $r3 == $y4 != $y3")
  or diag(defined($y4),"/<$y4>==$r3\n",
	  "child output [3] was $g");

##################################################################

sub getSimpleMask {
  my $n = shift;
  my $r = int(rand() * $n);
  return 1 << $r;
}

sub getComplexMask {
  my $n = shift;
  if ($n < 3) {
    return getSimpleMask($n);
  }
  my $s = 2 ** $n;
  my $r;
  do {
    $r = 1 + int(rand($s - 2));
  } while ( $r == 0                  # don't want no bits set 
	   || ($r & ($r-1)) == 0     # don't want one bit set
	   || ($r+1) == 2**$n );     # don't want all bits set
  return $r;
}

sub getUnbindMask {
  my $n = shift;
  return 2 ** $n - 1;
}
