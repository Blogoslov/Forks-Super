use Forks::Super ':test';
use Test::More tests => 24;
use strict;
use warnings;

### scalar context ###
#
# result is a tie'd scalar, so exercise fetch/store
#

ok(!defined $Forks::Super::LAST_JOB, 
   "$$\\\$Forks::Super::LAST_JOB not set");
ok(!defined $Forks::Super::LAST_JOB_ID, 
   "\$Forks::Super::LAST_JOB_ID not set");

delete $Forks::Super::Config::CONFIG{"YAML::Tiny"};
$Forks::Super::Config::CONFIG{"JSON"} = 0;
$Forks::Super::Config::CONFIG{"YAML"} = 0;
$Forks::Super::Config::CONFIG{"Data::Dumper"} = 0;

SKIP: {
    if ($ENV{NO_YAML} || !Forks::Super::Config::CONFIG_module("YAML::Tiny")) {
	skip "YAML::Tiny not available, skipping bg_eval tests", 22;
    }

    require "./t/62b-bg_eval.tt";
}

