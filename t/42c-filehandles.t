use Forks::Super ':test';
use Test::More tests => 9;
use Carp;
use strict;
use warnings;

#
# test whether the parent can have access to the
# STDIN, STDOUT, and STDERR filehandles from a
# child process when the child process uses
# the "cmd" option to run a shell command.
#


$SIG{SEGV} = sub { Carp::cluck "SIGSEGV caught!\n" };


#######################################################
my (@cmd,$pid,$fh_in,$z,$t,@out,@err,$msg);
@cmd = ($^X, "t/external-command.pl", "-s=2", "-y=2");

# test read_stderr

$pid = fork { cmd => [ @cmd , "-y=3" ], timeout => 6,
		child_fh => "in,err" };
ok(isValidPid($pid), "started job with join");

$msg = sprintf "the message is %x", rand() * 99999999;
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "$msg\n";
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "That was a test\n";
ok($z > 0, "successful print to child STDIN");
ok(defined $Forks::Super::CHILD_STDIN{$pid}, "CHILD_STDIN value defined [child_fh]");
ok(!defined $Forks::Super::CHILD_STDOUT{$pid}, "CHILD_STDOUT value not defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "CHILD_STDERR value defined");
$t = time;
@out = ();
@err = ();
while (time < $t+7) {
  my @data = Forks::Super::read_stdout($pid);
  push @out, @data if @data>0 and $data[0] ne "";

  @data = Forks::Super::read_stderr($pid);
  push @err, @data if @data>0 and $data[0] ne "";
}

########## this is a failure point in BSD, linux #############
# maybe some warning message is getting in the output stream

if (@out != 0 || @err != 2) {
  $Forks::Super::DONT_CLEANUP = 1;
  print STDERR "\n+stderr -stdout test: failure imminent\n";
  print STDERR "We expect no lines from stdout and two from stderr\n";
  print STDERR "What we get is:\n";
  print STDERR "--------------------------- \@out ------------------\n";
  print STDERR @out,"\n";
  print STDERR "--------------------------- \@err ------------------\n";
  print STDERR @err,"\n----------------------------------------------------\n";
}

ok(@out == 0, "got no output from child");
ok(@err == 2, "received error msg from child " . scalar @err . "\n$err[0]\n");
ok($err[0] =~ /received message $msg/, "got Expected first line from child error msg");
ok($err[1] =~ /a test/, "got Expected second line from child error msg");
waitall; 

##################################################
