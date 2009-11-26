use Forks::Super ':test';
use Test::More tests => 17;
use strict;
use warnings;

#
# test forking and invoking a shell command
#


my @cmd = ($^X,"t/external-command.pl",
	"-o=t/out/test", "-e=Hello,", "-e=Whirled",
	"-p", "-x=0");
my $cmd = "@cmd";

# test  fork  cmd => \@

unlink "t/out/test";
my $pid = fork {cmd => \@cmd };
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

# test  fork  cmd => $

unlink "t/out/test";
$pid = fork { cmd => $cmd };
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

$pid = fork { cmd => [ $^X, "t/external-command.pl", "-s=5" ] };
ok(isValidPid($pid), "fork to external command");
my $t = time;
$p = wait;
$t = time - $t;
ok($p == $pid, "wait reaped correct pid");
ok($t >= 5 && $t <= 6, "background command ran for ${t}s, expected 5-6s");

##################################################################

# test exit status

$pid = fork { cmd => [ $^X, "t/external-command.pl", "-x=5" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok(($?>>8) == 5, "captured correct non-zero status  $?");

##################################################################

$pid = fork { cmd => [ $^X, "t/external-command.pl", "-x=0" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok($? == 0, "captured correct zero status");

__END__
-------------------------------------------------------

Feature:	fork to shell command

What to test:	run a shell command
			concatenated args and split args
		verify that it ran in the background
		verify that it ran for the correct amount of time
		verify that it produced the correct output
		verify that it returned the correct status
			zero and non-zero

-------------------------------------------------------

