use Forks::Super ':test';
use Test::More tests => 32;
use strict;
use warnings;

#
# test whether the parent can have access to the
# STDIN, STDOUT, and STDERR filehandles from a
# child process when the child process uses
# the "cmd" option to run a shell command.
#




#######################################################

my @cmd = ($^X, "t/external-command.pl", "-s=2", "-y=2");
my $pid = fork { cmd => [ @cmd ], timeout => 5,
		get_child_stdin => 1, get_child_stdout => 1, 
                get_child_stderr => 1 };

ok(isValidPid($pid), "fork successful");
ok(defined $Forks::Super::CHILD_STDIN{$pid}, "\%CHILD_STDIN defined");
ok(defined $Forks::Super::CHILD_STDOUT{$pid}, "\%CHILD_STDOUT defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "\%CHILD_STDERR defined");
my $msg = sprintf "%x", rand() * 99999999;
my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
close $fh_in;
ok($z > 0, "print to child STDIN successful");
my $t = time;
my $fh_out = $Forks::Super::CHILD_STDOUT{$pid};
my $fh_err = $Forks::Super::CHILD_STDERR{$pid};
my (@out, @err) = ();
while (time < $t+6) {
  push @out, <$fh_out>;
  push @err, <$fh_err>;
  sleep 1;
  seek $fh_out,0,1;
  seek $fh_err,0,1;
}

# this is a failure point on many systems
# perhaps some warning message is getting in the output stream?
if (@out != 3 || @err != 1) {
  print STDERR "\nbasic ipc test: failure imminent\n";
  print STDERR "We expect three lines from stdout and one from stderr\n";
  print STDERR "What we get is:\n";
  print STDERR "--------------------------- \@out ------------------\n";
  print STDERR @out,"\n";
  print STDERR "--------------------------- \@err ------------------\n";
  print STDERR @err,"\n----------------------------------------------------\n";
}

ok(@out == 3, scalar @out . " == 3 lines from STDOUT");
ok(@err == 1, scalar @err . " == 1 line from STDERR");
ok($out[0] eq "$msg\n", "got expected first line from child");
ok($out[1] eq "$msg\n", "got expected second line from child");
ok($out[2] eq "\n", "got expected third line from child");
ok($err[0] =~ /received message $msg/, "got expected msg on child stderr");
waitall;

#######################################################

# test join, read_stdout
# 

$pid = fork { cmd => [ @cmd ], timeout => 5,
	    get_child_stdin => 1, get_child_stdout => 1,
            join_child_stderr => 1 };
ok(isValidPid($pid), "started job with join");

$msg = sprintf "the message is %x", rand() * 99999999;
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "$msg\n";
ok($z > 0, "successful print to child STDIN");
ok(defined $Forks::Super::CHILD_STDIN{$pid}, "CHILD_STDIN value defined");
ok(defined $Forks::Super::CHILD_STDOUT{$pid}, "CHILD_STDOUT value defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "CHILD_STDERR value defined");
ok($Forks::Super::CHILD_STDOUT{$pid} eq $Forks::Super::CHILD_STDERR{$pid},
   "child stdout and stderr go to same fh");
$t = time;
@out = ();
while (time < $t+6) {
  while ((my $line = Forks::Super::read_stdout($pid))) {
    push @out,$line;

    if (defined $line && length $line > 0) {
      print "READ LINE FOR $pid STDOUT:  $line\n";
    }

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
  print STDERR "File contents:\n-----------\n",<F>,"------------------\n";
  close F;

}

@out = grep { !/alarm\(\) not available/ } @out;
ok(@out == 4, scalar @out . " should be 4"); # 18 #
ok($out[-4] =~ /the message is/, "got expected first line from child");
ok($out[-4] eq "$msg\n", "got expected first line from child");
ok($out[-3] eq "$msg\n", "got expected second line from child");
ok($out[-2] eq "received message $msg\n"
	|| $out[-1] eq "received message $msg\n", "got expected third line from child");
ok($out[-1] eq "\n" || $out[-2] eq "\n", "got expected fourth line from child");
waitall;

#######################################################

# test read_stderr

$pid = fork { cmd => [ @cmd , "-y=3" ], timeout => 6,
	    get_child_stdin => 1, get_child_stdout => 0, 
            get_child_stderr => 1 };
ok(isValidPid($pid), "started job with join");

$msg = sprintf "the message is %x", rand() * 99999999;
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "$msg\n";
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "That was a test\n";
ok($z > 0, "successful print to child STDIN");
ok(defined $Forks::Super::CHILD_STDIN{$pid}, "CHILD_STDIN value defined");
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
  print STDERR "\n+stderr -stdout test: failure imminent\n";
  print STDERR "We expect no lines from stdout and two from stderr\n";
  print STDERR "What we get is:\n";
  print STDERR "--------------------------- \@out ------------------\n";
  print STDERR @out,"\n";
  print STDERR "--------------------------- \@err ------------------\n";
  print STDERR @err,"\n----------------------------------------------------\n";
}

ok(@out == 0, "got no output from child");
ok(@err == 2, "recevied error msg from child");
ok($err[0] =~ /received message $msg/, "got expected first line from child error msg");
ok($err[1] =~ /a test/, "got expected second line from child error msg");
waitall; 

##################################################

__END__
-------------------------------------------------------

Feature:	fork with filehandles (file)

What to test:	cmd style
		parent can send data to child through child_stdin{}
		child can send data to parent through child_stdout{}
		child can send data to parent through child_stderr{}
		join_stdout option puts child stdout/stderr through same fh
		parent detects when child is complete and closes filehandles
		parent can clear eof on child filehandles
		clean up
		parent/child back-and-forth proof of concept 
		master/slave proof-of-concept

-------------------------------------------------------
