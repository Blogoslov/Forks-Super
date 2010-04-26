use Forks::Super ':test_config';
use Test::More tests => 1;

# show some items and modules that could be configured on this system.

ok(1);

print STDERR "\n";
Forks::Super::CONFIG("Time::HiRes");
Forks::Super::CONFIG("Win32");
Forks::Super::CONFIG("Win32::API");
Forks::Super::CONFIG("Win32::Process");
Forks::Super::CONFIG("SIGUSR1");
Forks::Super::CONFIG("getpgrp");
Forks::Super::CONFIG("alarm");
Forks::Super::CONFIG("/taskset");
Forks::Super::CONFIG("/uptime");
Forks::Super::CONFIG("BSD::Process::Affinity");
