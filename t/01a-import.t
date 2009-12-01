use Forks::Super MAX_PROC => 9, CHILD_FORK_OK => -1;
use Test::More tests => 2;

ok($Forks::Super::MAX_PROC == 9);
ok($Forks::Super::CHILD_FORK_OK == -1);

