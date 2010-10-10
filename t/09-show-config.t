use Forks::Super ':test_config';
use Test::More tests => 1;
use strict;
use warnings;

# show some items and modules that could be configured on this system.
# This test is included mostly so that I can get more detail about
# the CPAN testers' configuration.

if (${^TAINT}) {
  $ENV{PATH} = "";
}


print STDERR "\n";
Forks::Super::Config::CONFIG_module("Time::HiRes");
Forks::Super::Config::CONFIG_module("Win32");
Forks::Super::Config::CONFIG_module("Win32::API");
Forks::Super::Config::CONFIG_module("Win32::Process");
Forks::Super::Config::CONFIG_Perl_component("SIGUSR1");
Forks::Super::Config::CONFIG_Perl_component("getpgrp");
Forks::Super::Config::CONFIG_Perl_component("alarm");
Forks::Super::Config::CONFIG_module("Sys::CpuAffinity");
Forks::Super::Config::CONFIG_module("Sys::CpuLoadX");
Forks::Super::Config::CONFIG_external_program("/uptime");

my $ps = $ENV{PERL_SIGNALS} || "";
print STDERR "\$ENV{PERL_SIGNALS} = $ps\n";

print STDERR "Forks::Super::Job is overloaded: ",
	$Forks::Super::Job::OVERLOAD_ENABLED, "\n";

print STDERR "\n";
ok(1);
