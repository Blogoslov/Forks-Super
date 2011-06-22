use Sys::CpuAffinity;
use Test::More tests => 1;
use strict;
use warnings;

# output the relevant configuration of this system.
# when test t/10-exercise.t doesn't pass,
# this information is helpful in discovering why

print STDERR "\n\nSystem configuration\n====================\n";

print STDERR "\$^O = $^O; \$] = $]\n";


my @xs = grep { eval "defined &Sys::CpuAffinity::$_" }
         grep { /^xs/ } keys %Sys::CpuAffinity::;
if (@xs) {
    print STDERR "Defined XS functions:\n\t";
    print STDERR join "\n\t", sort @xs;
    print STDERR "\n\n";
}

foreach my $module (qw(Win32::API Win32::Process BSD::Process::Affinity)) {
  my $avail = Sys::CpuAffinity::_configModule($module);
  if ($avail) {
    no warnings 'uninitialized';
    $avail .= eval "\$$module" . "::VERSION";
  }
  print STDERR "module $module: ", ($avail || "not"), " available\n";
}

foreach my $externalProgram (qw(bindprocessor dmesg sysctl psrinfo hinv
				hwprefs system_profiler prtconf 
				taskset pbind cpuset)) {

  my $path = Sys::CpuAffinity::_configExternalProgram($externalProgram);
  if ($path) {
    print STDERR "$externalProgram available at: $path\n";
  } else {
    print STDERR "$externalProgram: not found\n";
  }
}
print STDERR "\n";

ok(1);
