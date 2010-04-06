use Forks::Super ':test';
use Test::More tests => 35;
use strict;
use warnings;

### scalar context ###
#
# result is a tie'd scalar, so exercise fetch/store
#

no warnings 'once';
ok(!defined $Forks::Super::LAST_JOB, 
   "$$\\\$Forks::Super::LAST_JOB not set");
ok(!defined $Forks::Super::LAST_JOB_ID, 
   "\$Forks::Super::LAST_JOB_ID not set");

delete $Forks::Super::Config::CONFIG{"YAML"};
$Forks::Super::Config::CONFIG{"JSON"} = 0;


if ($ENV{NO_YAML} || !Forks::Super::Config::CONFIG("YAML")) {
 SKIP: {
    skip "YAML not available, skipping bg_eval tests", 33;
  }
  exit 0;
}

require "t/62-bg_eval.tt";


