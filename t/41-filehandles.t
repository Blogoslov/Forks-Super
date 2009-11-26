use Forks::Super ':test';
use Test::More tests => 31;
use strict;
use warnings;
if (Forks::Super::CONFIG("alarm")) {
  alarm 90;$SIG{ALRM} = sub { die "Timeout\n" };
}

#
# test whether a parent process can have access to the
# STDIN, STDOUT, and STDERR filehandles of a child
# process. This will allow two-way communication.
#


# this is a subroutine that copies STDIN to STDOUT and optionally STDERR
sub repeater {
  my ($n, $e) = @_;
  my $end_at = time + 5;
  sleep 2;
  while (time < $end_at) {
    if (defined ($_ = <STDIN>)) {
      if ($e) {
        print STDERR $_;
      }
      for (my $i = 0; $i < $n; $i++) {
        print STDOUT "$i:$_";
      }
    }
    seek STDIN, 0, 1;
  }
  close STDOUT;
  close STDERR;
}

#######################################################

my $pid = fork { sub => \&repeater, timeout => 6, args => [ 3, 1 ], 
              	 get_child_stdin => 1, get_child_stdout => 1, 
		 get_child_stderr => 1 };

ok(isValidPid($pid), "pid $pid valid");
ok(defined $Forks::Super::CHILD_STDIN{$pid},"found stdin fh");
ok(defined $Forks::Super::CHILD_STDOUT{$pid},"found stdout fh");
ok(defined $Forks::Super::CHILD_STDERR{$pid},"found stderr fh");
my $msg = sprintf "%x", rand() * 99999999;
my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
close $fh_in;
ok($z > 0, "print to child stdin successful");
my $t = time;
my $fh_out = $Forks::Super::CHILD_STDOUT{$pid};
my $fh_err = $Forks::Super::CHILD_STDERR{$pid};
my (@out,@err);
while (time < $t+10) {
  push @out, <$fh_out>;
  push @err, <$fh_err>;
  sleep 1;
  seek $fh_out,0,1;
  seek $fh_err,0,1;

# print "\@out:\n------\n@out\n\@err:\n-------\n@err\n";
}

ok(@out == 3, scalar @out . " == 3 lines from STDOUT   [ @out ]");

@err = grep { !/alarm\(\) not available/ } @err;  # exclude warning to child STDERR
ok(@err == 1, scalar @err . " == 1 line from STDERR\n" . join $/,@err);

ok($out[0] eq "0:$msg\n", "got expected first line from child output");
ok($out[1] eq "1:$msg\n", "got expected second line from child output");
ok($out[2] eq "2:$msg\n", "got expected third line from child output");
ok($err[-1] eq "$msg\n", "got expected line from child error");
waitall;

#######################################################

# test join, read_stdout

$pid = fork { sub => \&repeater , args => [ 2, 1 ] , timeout => 6,
	    get_child_stdin => 1, get_child_stdout => 1, join_child_stderr => 1 };
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
while (time < $t+7) {
  while ((my $line = Forks::Super::read_stdout($pid))) {
    push @out, $line;
  }
}

###### these 5 tests were a failure point on versions 0.04,0.05 ######
# perhaps some warning message was getting into the output stream
if (@out != 3) {
  print STDERR "\ntest join+read stdout: failure imminent.\n";
  print STDERR "Expecting three lines but what we get is:\n";
  my $i;
  print STDERR map { ("Output line ", ++$i , ": $_") } @out;
  print STDERR "\n";
}

@out = grep { !/alarm\(\) not available/ } @out;
ok(@out == 3, "read ".(scalar @out)." [3] lines from child STDOUT:   @out"); # 18 #
ok($out[-3] =~ /the message is/, "first line matches expected pattern");
ok($out[-3] eq "$msg\n", "first line matches expected pattern");
ok($out[-2] eq "0:$msg\n", "second line matches expected pattern");
ok($out[-1] eq "1:$msg\n", "third line matches expected pattern");
waitall;

#######################################################

# test read_stderr

$pid = fork { sub => \&repeater , args => [ 3, 1 ] , timeout => 6,
	    get_child_stdin => 1, get_child_stdout => 0, get_child_stderr => 1 };
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
ok(@out == 0, "received no output from child");
@err = grep { !/alarm\(\) not available/ } @err;
ok(@err == 2, "received 2 lines from child stderr");
ok($err[-2] =~ /the message is/, "got expected first line from child error");
ok($err[-1] =~ /a test/, "got expected second line from child error");
waitall; 

##################################################

# get filehandles by job ID

__END__
-------------------------------------------------------

Feature:	fork with filehandles (file)

What to test:	sub style or natural style
		parent can send data to child through child_stdin{}
		child can send data to parent through child_stdout{}
		child can send data to parent through child_stderr{}
		join_child_stdout option puts child stdout/stderr through same fh

		parent detects when child is complete and closes filehandles
		parent can clear eof on child filehandles
		clean up
		parent/child back-and-forth proof of concept 
		master/slave proof-of-concept

-------------------------------------------------------
