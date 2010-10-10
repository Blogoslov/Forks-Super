use Forks::Super ':test_CA';
use Test::More tests => 21;
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

my $output = "t/out/test11.$$";
my @cmd = ($^X,"t/external-command.pl",
	"-o=$output", "-e=Hello,", "-e=Whirled",
	"-p", "-x=0");
my $cmd = "@cmd";

# test  fork  cmd => \@

unlink $output;
my $pid = fork {cmd => \@cmd };
ok(isValidPid($pid), "$$\\fork to \@command successful");
my $p = Forks::Super::wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child STATUS \$? == 0");
my $z = do { my $fh; open($fh, "<", $output); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
my $target_z = "Hello, Whirled $pid";
ok($z eq $target_z, 
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test  fork  cmd => $

unlink $output;
$pid = fork { cmd => $cmd };
ok(isValidPid($pid), "fork to \$command successful");
$p = wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child STATUS \$? == 0");
$z = do { my $fh; open($fh, "<", $output); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
$target_z = "Hello, Whirled $pid";
ok($z eq $target_z,
	"child produced child output \'$z\' vs. \'$target_z\'");    ### 8 ###

##################################################################

# test that timing of reap is correct

my $u = Time::HiRes::gettimeofday();
$pid = fork { cmd => [ $^X, "t/external-command.pl", "-s=5" ] };
ok(isValidPid($pid), "fork to external command");
my $t = Time::HiRes::gettimeofday();
$p = wait;
my $v = Time::HiRes::gettimeofday();
($t,$u) = ($v-$t, $v-$u);
ok($p == $pid, "wait reaped correct pid");
ok($u >= 4.9 && $t <= 9.05,             ### 11 ### was 6.5 obs 8.02,9.33,8.98
   "background command ran for ${t}s ${u}s, expected 5-6s");

##################################################################

# test exit status

$pid = fork { cmd => [ $^X, "t/external-command.pl", "-x=5" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok(($?>>8) == 5, "captured correct non-zero STATUS  $?");

##################################################################

$pid = fork { cmd => [ $^X, "t/external-command.pl", "-x=0" ] };
ok(isValidPid($pid), "fork to external command");
$p = wait;
ok($p == $pid, "wait reaped correct pid");
ok($? == 0, "captured correct zero STATUS");

#############################################################################

# list context

$Forks::Super::SUPPORT_LIST_CONTEXT = 1;
($pid, my $j) = fork { cmd => [ $^X, "t/external-command.pl", "-x=14" ] };
ok(isValidPid($pid), "fork to external command, list context");
ok(defined($j) && ref $j eq 'Forks::Super::Job', 
   "fork gets job in list context");
ok($j->{pid} == $pid && $j->{real_pid} == $pid, "pid saved in list context");
$p = wait;
ok($j->{status} == 14 << 8, "correct job status avail in list context");

#############################################################################

unlink $output;


