use Forks::Super ':test_config';
use Test::More tests => 1;

# show some items and modules that could be configured on this system.
# This test is included mostly so that I can get more detail about
# the CPAN testers' configuration.

if (${^TAINT}) {
  $ENV{PATH} = "";
}

ok(1);

print STDERR "\n";
Forks::Super::CONFIG("Time::HiRes");
Forks::Super::CONFIG("Win32");
Forks::Super::CONFIG("Win32::API");
Forks::Super::CONFIG("Win32::Process");
Forks::Super::CONFIG("SIGUSR1");
Forks::Super::CONFIG("getpgrp");
Forks::Super::CONFIG("alarm");
Forks::Super::CONFIG("Sys::CpuAffinity");
Forks::Super::CONFIG("Sys::CpuLoadX");
Forks::Super::CONFIG("/uptime");
print STDERR "\$ENV{PERL_SIGNALS} = $ENV{PERL_SIGNALS}\n";

