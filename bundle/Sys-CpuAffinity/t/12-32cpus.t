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

my $mask = getSimpleMask($ncpus);
my $clear = getUnbindMask($ncpus);

if ($ncpus < 32) {
  no warnings 'redefine';
  *Sys::CpuAffinity::getNumCpus = sub () { return 32 };
} else {
  print STDERR "This system actually has $ncpus cpus.\n";
}
my $n = Sys::CpuAffinity::getNumCpus();
ok($n >= 32, "getNumCpus() returns $n>=32 (possibly after redefine)");

my $y0 = Sys::CpuAffinity::getAffinity($$);
if ($^O =~ /solaris/i) {
  $y0 &= $clear;
}
ok($y0 > 0 && $y0 <= $clear, "got affinity $y0");

my $z1 = Sys::CpuAffinity::setAffinity($$, $mask);
ok($z1 != 0, "set affinity ok on 32-cpu system $z1 != 0");

my $y1 = Sys::CpuAffinity::getAffinity($$);
ok($y1 == $mask, "got affinity $y1 == $mask");

my $z2 = Sys::CpuAffinity::setAffinity($$, -1);
ok($z2 != 0, "clear affinity probably ok on 32-cpu system $z2 != 0");

my $y2 = Sys::CpuAffinity::getAffinity($$);
if ($^O =~ /solaris/i) {
  $y2 &= $clear;
}
ok($y2 == $clear, "got affinity $y2 == $clear");

sub getSimpleMask {
  my $n = shift;
  my $r = int(rand() * $n);
  return 1 << $r;
}

sub getUnbindMask {
  my $n = shift;
  my $s = 1 << ($n - 1);
  return 2 * ($s - 1) + 1;
}
