use Forks::Super DEBUG => 1, ON_BUSY => "bogus";
use Test::More tests => 2;

ok($Forks::Super::DEBUG == 1);
ok($Forks::Super::ON_BUSY ne "bogus");



