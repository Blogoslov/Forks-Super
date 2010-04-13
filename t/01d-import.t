use Test::More tests => 1;
use Forks::Super FH_DIR => ".";

ok($Forks::Super::FH_DIR eq "." || $Forks::Super::FH_DIR =~ m{\./\.fhfork});

