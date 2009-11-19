#
# test that Forks module loads and that the expected
# functions are exported to the calling package
#
use strict;
use warnings;

use Test::More tests => 10;
BEGIN {
	use_ok('Forks::Super');
}

ok(\&Forks::Super::fork ne \&CORE::fork);
ok(\&fork eq \&Forks::Super::fork);

ok(\&wait ne \&CORE::wait);
ok(\&wait eq \&Forks::Super::wait);

ok(\&waitpid ne \&CORE::waitpid);
ok(\&waitpid eq \&Forks::Super::waitpid);

ok(\&waitall eq \&Forks::Super::waitall);

my $t = fork {'__test' => 14}  ;
ok($t == 14, "fork invokes Forks::Super::fork, not CORE::fork");

$t = fork '__test' => 14  ;
ok($t == 14, "fork invokes Forks::Super::fork, not CORE::fork");

__END__
