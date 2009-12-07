use Forks::Super ':test_config';
use Test::More tests => 1;

# show some items that could be configured on this system.
# it usually 

ok(1);

print STDERR "\n";
Forks::Super::CONFIG("Time::HiRes");
Forks::Super::CONFIG("Win32");
Forks::Super::CONFIG("Win32::API");
Forks::Super::CONFIG("Win32::Process");
Forks::Super::CONFIG("SIGUSR1");
Forks::Super::CONFIG("getpgrp");
Forks::Super::CONFIG("alarm");
Forks::Super::CONFIG("filehandles");
Forks::Super::CONFIG("/bin/taskset");
Forks::Super::CONFIG("BSD::Process::Affinity");
