use Test::More tests => 1;
use Forks::Super FH_DIR => ".";
use strict;
use warnings;

ok($Forks::Super::FH_DIR eq "." || $Forks::Super::FH_DIR =~ m{\./\.fhfork});

