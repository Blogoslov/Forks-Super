use Forks::Super ':test';
use Test::More tests => 35;
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

delete $Forks::Super::Config::CONFIG{"YAML"};
$Forks::Super::Config::CONFIG{"JSON"} = 0;

SKIP: {

  if ($ENV{NO_YAML} || !Forks::Super::Config::CONFIG_module("YAML")) {
    skip "YAML not available, skipping bg_eval tests", 33;
  }
  do "./t/62a-bg_eval.tt";

}



