use Forks::Super MAX_PROC => 18, ON_BUSY => "queue";
use Test::More tests => 2;

ok($Forks::Super::MAX_PROC == 18);
ok($Forks::Super::ON_BUSY eq "queue");


