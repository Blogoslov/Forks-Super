use Forks::Super ':test';
use Forks::Super::Util qw(is_socket);
use Test::More tests => 12;
use Carp;
use strict;
use warnings;

#
# complex commands (with pipes) that expect
# input require special handling
#
if (${^TAINT}) {
  $ENV{PATH} = "";
  ($^X) = $^X =~ /(.*)/;
}

#######################################################

my $command1 = "$^X t/external-command.pl -s=2 -y=2";
my $command2 = "$^X t/external-command.pl -y=10 -y=4";
my $cmd = "$command1 | $command2";
my $msg = sprintf "%x", rand() * 99999999;

my $pid = fork { cmd => $cmd, timeout => 5, child_fh => "all,socket" };

ok(isValidPid($pid), "$$\\fork successful");
ok(defined $Forks::Super::CHILD_STDIN{$pid},  "\%CHILD_STDIN defined");
ok(defined $Forks::Super::CHILD_STDOUT{$pid}, "\%CHILD_STDOUT defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "\%CHILD_STDERR defined");

if ($^O eq 'MSWin32') {
  ok(!is_socket($Forks::Super::CHILD_STDIN{$pid}),
     "CHILD_STDIN is not a socket for cmd-style fork on MSWin32");
  ok(!is_socket($Forks::Super::CHILD_STDOUT{$pid}),
     "CHILD_STDOUT is not a socket for cmd-style fork on MSWin32");
} else {
  ok(is_socket($Forks::Super::CHILD_STDIN{$pid}),
     "CHILD_STDIN is a socket for cmd-style fork");
  ok(is_socket($Forks::Super::CHILD_STDOUT{$pid}),
     "CHILD_STDOUT is a socket for cmd-style fork");
}

my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
ok($z > 0, "print to child STDIN successful");

my $t = Time::HiRes::gettimeofday();
waitpid $pid, 0;
$t = Time::HiRes::gettimeofday() - $t;
ok($t > 1.01 && $t < 6.15,              ### 8 ### was 1.25/5.05,obs 1.05/6.12
   "compound command took ${t}s, expected ~2s");
sleep 1;

my @out = Forks::Super::read_stdout($pid);
my @err = Forks::Super::read_stderr($pid);
ok(@out == 15, "got 15==" . scalar @out . " lines of output");
if (@out < 10) {
  print STDERR "Output was:\n---------\n@out\n--------------\n";
}

# could be 2 or 3 lines of error output, it's OS-dependent.
# It depends on whether the error from $command1
# makes it to the $cmd error output stream.

ok(@err == 2 || @err==3, "got " . scalar @err . "==2|3 lines of error");
ok($out[0] eq "$msg\n", "got expected output from child");
ok($err[0] =~ /received message $msg/, "got expected error from child");
Forks::Super::close_fh($pid, 'stdin');
waitall;
