use Forks::Super ':test_CA';
use Test::More tests => 1;
# use IPC::Run;
use strict;
use warnings;

# placeholder for testing  fork { run => \@ } feature.

if (${^TAINT}) {
    $ENV{PATH} = "";
    ($^X) = $^X =~ /(.*)/;
    ($ENV{HOME}) = $ENV{HOME} =~ /(.*)/;
}

my $output = "t/out/test14.$$";
my @cmd = qw(cat);
my $in = "hello world\n";
my ($out,$err);


ok(1);
exit;

__END__
my @run1 = ( [ @cmd ], \$in, \$out, \$err, IPC::Run::timeout(10) );

my $p = fork { run => \@run1 };
waitall;
