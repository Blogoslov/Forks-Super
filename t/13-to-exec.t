use Forks::Super ':test_CA';
use Test::More tests => 17;
use strict;
use warnings;

#
# test forking and invoking a shell command
#
if (${^TAINT}) {
    $ENV{PATH} = "";
    ($^X) = $^X =~ /(.*)/;
    ($ENV{HOME}) = $ENV{HOME} =~ /(.*)/;
}

my $output = "t/out/test13.$$";
my @cmd = ($^X,"t/external-command.pl",
	"-o=$output", "-e=Hello,", "-e=Whirled",
	"-P", "-x=0");
my $cmd = "@cmd";

# test  fork  exec => \@

unlink $output;
my $pid = fork {exec => \@cmd };
ok(isValidPid($pid), "fork to \@command successful");
my $p = Forks::Super::wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child STATUS \$? == 0");
my $z = do { my $fh; open($fh, "<", $output); 
	     my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
my $target_z = "Hello, Whirled $pid";
ok($z eq $target_z, 
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test  fork  exec => $

unlink $output;
$pid = fork { exec => $cmd };
ok(isValidPid($pid), "fork to \$command successful");
$p = wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child STATUS \$? == 0");
$z = do { my $fh; open($fh, "<", $output); 
	  my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
$target_z = "Hello, Whirled $pid";
ok($z eq $target_z,
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test that timing of reap is correct

$pid = fork { exec => [ $^X, "t/external-command.pl", "-s=5" ] };
ok(isValidPid($pid), "fork to external command");
my $t = Time::HiRes::time();
$p = wait;
$t = Time::HiRes::time() - $t;
ok($p == $pid, "wait reaped correct pid");
okl($t > 4.4 && $t < 10.05,         ### 11 ### was 7.05,obs 8.02,11.96
   "background command ran for ${t}s, expected 5-6s");

##################################################################

# test exit status

$pid = fork { exec => [ $^X, "t/external-command.pl", "-x=5" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok(($?>>8) == 5, "captured correct non-zero STATUS  $?");

##################################################################

$pid = fork { exec => [ $^X, "t/external-command.pl", "-x=0" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok($? == 0, "captured correct zero STATUS");

##################################################################

unlink $output;
