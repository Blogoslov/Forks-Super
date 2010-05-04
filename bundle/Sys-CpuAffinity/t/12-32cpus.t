use Sys::CpuAffinity;
use Test::More tests => 6;
use strict;
use warnings;

# version 0.90 had a bug when there were exactly 32 processors
# (so that  1 << ncpu == 1)

my $ncpus = Sys::CpuAffinity::getNumCpus();
if ($ncpus <= 1) {
 SKIP: {
    skip "can't test affinity on single cpu system", 6;
  }
  exit 0;
}
if ($^O =~ /darwin/i || $^O =~ /MacOS/i) {
 SKIP: {
    skip "test affinity on MacOS not supported", 6;
  }
  exit 0;
}

my $mask = getSimpleMask($ncpus);
my $clear1 = getUnbindMask($ncpus);
my $clear2 = -1;
my $clear = $^O =~ /solaris/i ? $clear2 : $clear1;

if ($ncpus < 32) {
  no warnings 'redefine';
  *Sys::CpuAffinity::getNumCpus = sub () { return 32 };
  print STDERR "This system has $ncpus cpus. ",
	"Spoofing Sys::CpuAffinity::getNumCpus() to return 32\n";
} else {
  print STDERR "This system actually has $ncpus cpus.\n";
}
my $n = Sys::CpuAffinity::getNumCpus();
ok($n >= 32, "getNumCpus() returns $n>=32 (possibly after redefine)");

my $y0 = Sys::CpuAffinity::getAffinity($$);
if ($^O =~ /solaris/i) {
  $y0 &= $clear1;
}
ok($y0 > 0 && $y0 <= $clear1, "got affinity $y0");

my $z1 = Sys::CpuAffinity::setAffinity($$, $mask);
ok($z1 != 0, "set affinity ok on 32-cpu system $z1 != 0");

my $y1 = Sys::CpuAffinity::getAffinity($$);
ok($y1 == $mask, "got affinity $y1 == $mask");

my $z2 = Sys::CpuAffinity::setAffinity($$, $clear);
ok($z2 != 0, "clear affinity probably ok on 32-cpu system $z2 != 0");

my $y2 = Sys::CpuAffinity::getAffinity($$);
if ($^O =~ /solaris/i) {
  $y2 &= $clear1;
}
ok($y2 == $clear1, "got affinity $y2 == $clear1");

sub getSimpleMask {
  my $n = shift;
  my $r = int(rand() * $n);
  return 1 << $r;
}

sub getUnbindMask {
  my $n = shift;
  return 2 ** $n - 1;
}
