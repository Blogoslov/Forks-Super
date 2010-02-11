use Forks::Super ':test';
use Test::More tests => 17;
use strict;
use warnings;

#
# test forking and invoking a shell command
#

open(LOCK, ">>", "t/out/.lock-t11");
flock LOCK, 2;


my @cmd = ($^X,"t/external-command.pl",
	"-o=t/out/test", "-e=Hello,", "-e=Whirled",
	"-P", "-x=0");
my $cmd = "@cmd";

# test  fork  exec => \@

unlink "t/out/test";
my $pid = fork {exec => \@cmd };
ok(isValidPid($pid), "fork to \@command successful");
my $p = Forks::Super::wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child status \$? == 0");
my $z = do { my $fh; open($fh, "<", "t/out/test"); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
my $target_z = "Hello, Whirled $pid";
ok($z eq $target_z, 
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test  fork  exec => $

unlink "t/out/test";
$pid = fork { exec => $cmd };
ok(isValidPid($pid), "fork to \$command successful");
$p = wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child status \$? == 0");
$z = do { my $fh; open($fh, "<", "t/out/test"); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
$target_z = "Hello, Whirled $pid";
ok($z eq $target_z,
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test that timing of reap is correct

$pid = fork { exec => [ $^X, "t/external-command.pl", "-s=5" ] };
ok(isValidPid($pid), "fork to external command");
my $t = Forks::Super::Time();
$p = wait;
$t = Forks::Super::Time() - $t;
ok($p == $pid, "wait reaped correct pid");
ok($t >= 5 && $t <= 6.5, "background command ran for ${t}s, expected 5-6s");

##################################################################

# test exit status

$pid = fork { exec => [ $^X, "t/external-command.pl", "-x=5" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok(($?>>8) == 5, "captured correct non-zero status  $?");

##################################################################

$pid = fork { exec => [ $^X, "t/external-command.pl", "-x=0" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok($? == 0, "captured correct zero status");

close LOCK;
