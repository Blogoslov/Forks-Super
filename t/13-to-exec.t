use Forks::Super ':test';
use Test::More tests => 21;
use strict;
use warnings;

#
# test forking and invoking a shell command
#

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
ok($? == 0, "child status \$? == 0");
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
ok($? == 0, "child status \$? == 0");
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
my $t = Forks::Super::Util::Time();
$p = wait;
$t = Forks::Super::Util::Time() - $t;
ok($p == $pid, "wait reaped correct pid");
ok($t > 4.4 && $t < 10.05,         ### 11 ### was 7.05,obs 8.02,11.96
   "background command ran for ${t}s, expected 5-6s");

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

##################################################################

# list context
$Forks::Super::SUPPORT_LIST_CONTEXT = 1;
($pid,my $j) = fork { exec => [ $^X, "t/external-command.pl", "-x=22" ] };
ok(isValidPid($pid), "exec fork to external command, list context");
ok(defined($j) && ref $j eq 'Forks::Super::Job', 
   "fork gets job in list context");
ok($j->{pid} == $pid && $j->{real_pid} == $pid, "pid saved in list context");
$p = wait;
ok($j->{status} == 22 << 8, "correct job status avail in list context");

unlink $output;
