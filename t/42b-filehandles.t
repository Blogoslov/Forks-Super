use Forks::Super ':test';
use Test::More tests => 12;
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


#######################################################
# test join, read_stdout
# 

$pid = fork { cmd => [ @cmd ], timeout => 5,
		child_fh => "in,out,join" };
ok(isValidPid($pid), "started job with join");

$msg = sprintf "the message is %x", rand() * 99999999;
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "$msg\n";
ok($z > 0, "successful print to child STDIN");
ok(defined $Forks::Super::CHILD_STDIN{$pid}, "CHILD_STDIN value defined [child_fh]");
ok(defined $Forks::Super::CHILD_STDOUT{$pid}, "CHILD_STDOUT value defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "CHILD_STDERR value defined");
ok($Forks::Super::CHILD_STDOUT{$pid} eq $Forks::Super::CHILD_STDERR{$pid},
   "child stdout and stderr go to same fh");
$t = time;
@out = ();
while (time < $t+6) {
  while ((my $line = Forks::Super::read_stdout($pid, warn => 0))) {
    push @out,$line;
    if (@out > 100) {
      print STDERR "\nCrud. \@out is growing out of control:\n@out\n";
      $t -= 11;
      last;
    }
  }
}

###### these 5 tests were a failure point on many systems ######
# perhaps some warning message was getting into the output stream
if (@out != 4
	|| $out[-4] !~ /the message is/
	|| $out[-3] !~ /$msg/
	|| ($out[-2] !~ /$msg/ && $out[-1] !~ /$msg/)) {
  $Forks::Super::DONT_CLEANUP = 1;
  print STDERR "\ntest join+read stdout: failure imminent.\n";
  print STDERR "Expecting four lines but what we get is:\n";
  my $i;
  print STDERR map { ("Output line ", ++$i , ": $_") } @out;
  print STDERR "\n";
  print STDERR "Command was: \"@cmd\"\n";
  my $job = Forks::Super::Job::get($pid);

  my $file = $job->{fh_config}->{f_out};
  print STDERR "Output file was \"$file\"\n";
  open(F, "<", $file);
  print STDERR "File contents:\n------------\n",<F>,"------------\n";
  close F;

}

@out = grep { !/alarm\(\) not available/ } @out;
ok(@out == 4, scalar @out . " should be 4"); # 18 #
ok($out[-4] =~ /the message is/, "got Expected first line from child");
ok($out[-4] eq "$msg\n", "got Expected first line from child");
ok($out[-3] eq "$msg\n", "got Expected second line from child");
ok($out[-2] eq "received message $msg\n"
	|| $out[-1] eq "received message $msg\n", "got Expected third line from child");
ok($out[-1] eq "\n" || $out[-2] eq "\n", "got Expected fourth line from child");
waitall;

