#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Sys::CpuAffinity' ) || print "Bail out!
";
}

diag( "Testing Sys::CpuAffinity $Sys::CpuAffinity::VERSION, Perl $], $^X" );
