use Forks::Super;
use Test::More tests => 1;
use strict;
use warnings;

if (!Forks::Super::Config::CONFIG("Sys::CpuLoadX")) {
 SKIP: {
    skip "cpu load test: requires Sys::CpuLoadX module", 1;
  }
  exit 0;
}

my $load = Forks::Super::Job::OS::get_cpu_load();
ok($load > 0 || $load eq "0.00", "got current cpu load $load");
