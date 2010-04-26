use Forks::Super ':test';
use Test::More tests => 10;
use Carp;
use strict;
use warnings;

#
# complex commands (with pipes) that expect
# input require special handling
#


$SIG{SEGV} = sub { Carp::cluck "SIGSEGV caught!\n" };

#######################################################

my $command1 = "$^X t/external-command.pl -s=2 -y=2";
my $command2 = "$^X t/external-command.pl -y=10 -y=4";
my $cmd = "$command1 | $command2";
my $msg = sprintf "%x", rand() * 99999999;

my $pid = fork { cmd => $cmd, timeout => 5, child_fh => "all" };

ok(isValidPid($pid), "$$\\fork successful");
ok(defined $Forks::Super::CHILD_STDIN{$pid},  "\%CHILD_STDIN defined");
ok(defined $Forks::Super::CHILD_STDOUT{$pid}, "\%CHILD_STDOUT defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "\%CHILD_STDERR defined");

my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
close $fh_in;
ok($z > 0, "print to child STDIN successful");

my $t = Forks::Super::Util::Time();
waitpid $pid, 0;
$t = Forks::Super::Util::Time() - $t;
ok($t > 1.05 && $t < 5.05, "compound command took ${t}s, expected ~2s");
sleep 1;

my @out = Forks::Super::read_stdout($pid);
my @err = Forks::Super::read_stderr($pid);
ok(@out == 15, "got 15==" . scalar @out . " lines of output");
ok(@err == 2, "got 2==" . scalar @err . " lines of error");
ok($out[0] eq "$msg\n", "got expected output from child");
ok($err[0] =~ /received message $msg/, "got expected error from child");

