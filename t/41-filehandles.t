use Forks::Super ':test';
use Test::More tests => 33;
use strict;
use warnings;
if (Forks::Super::CONFIG("alarm")) {
  alarm 150;$SIG{ALRM} = sub { die "Timeout $0 ran too long\n" };
}

#
# test whether a parent process can have access to the
# STDIN, STDOUT, and STDERR filehandles of a child
# process. This features allows for communication
# between parent and child processes.
#

#
# 0.09 - added debugging code to sub repeater and to 
# the "read_stderr" test (tests 23-31). The read_stderr is
# a consistent failure point since 0.07 on some systems and
# I need to get a handle on what goes on during that test.
#



# this is a subroutine that copies STDIN to STDOUT and optionally STDERR
sub repeater {
  Forks::Super::debug("repeater: method beginning") if $Forks::Super::DEBUG;

  my ($n, $e) = @_;
  my $end_at = time + 6;
  my ($input_found, $input) = 1;

  sleep 3;
  Forks::Super::debug("repeater: ready to read input") if $Forks::Super::DEBUG;
  while (time < $end_at) {
    if (defined ($_ = <STDIN>)) {
      if ($Forks::Super::DEBUG) {
	$input = substr($_,0,-1);
	$input_found = 1;
	Forks::Super::debug("repeater: input was \"",substr($_,0,-1),"\"");
      }
      if ($e) {
        print STDERR $_;
	if ($Forks::Super::DEBUG) {
	  Forks::Super::debug("repeater: wrote \"$input\" to STDERR/",fileno(STDERR));
	}
      }
      for (my $i = 0; $i < $n; $i++) {
        print STDOUT "$i:$_";
	if ($Forks::Super::DEBUG) {
	  Forks::Super::debug("repeater: wrote [$i] \"$input\" to STDOUT/",
			      fileno(STDOUT));
	}
      }
    } elsif ($Forks::Super::DEBUG && $input_found) {
      $input_found = 0;
      Forks::Super::debug("repeater: no input");
    }
    seek STDIN, 0, 1;
  }
  if ($Forks::Super::DEBUG) {
    Forks::Super::debug("repeater: time expired. Not processing any more input");
  }
  close STDOUT;
  close STDERR;
}

#######################################################

my $pid = fork { sub => \&repeater, timeout => 10, args => [ 3, 1 ], 
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

$pid = fork { sub => \&repeater , args => [ 2, 1 ] , timeout => 10,
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
while (time < $t+12) {
  while ((my $line = Forks::Super::read_stdout($pid))) {
    push @out, $line;
  }
}

###### these 5 tests were a failure point on versions 0.04,0.05 ######
###### failure point in 0.06 because of "Timeout" #######

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

# test read_stderr -- this is the last significant failure point from 0.08
# the usual error is that @err contains one line instead of two
# let's retest with debugging if we detect that this test is going to fail ...

sub read_stderr_test {

  $pid = fork { sub => \&repeater , args => [ 3, 1 ] , timeout => 10,
		  get_child_stdin => 1, get_child_stdout => 0, get_child_stderr => 1 };

  my $z = 0;
  if (isValidPid($pid)) {
    my $msg = sprintf "the message is %x", rand() * 99999999;
    my $pid_stdin_fh = $Forks::Super::CHILD_STDIN{$pid};
    $z = print $pid_stdin_fh "$msg\n";
    if ($Forks::Super::DEBUG) {
      Forks::Super::debug("Printed \"$msg\\n\" to child stdin ($pid)");
    }
    sleep 1;
    $z = print $pid_stdin_fh "That was a test\n";
    if ($Forks::Super::DEBUG) {
      Forks::Super::debug("Printed \"That was a test\\n\" to child stdin ($pid)");
    }
    close $Forks::Super::CHILD_STDIN{$pid};
    if ($Forks::Super::DEBUG) {
      Forks::Super::debug("Closed filehandle to $pid STDIN");
    }
  }
  return ($z,$pid);
}

($z,$pid) = &read_stderr_test;
ok(isValidPid($pid), "started job with join");
ok($z > 0, "successful print to child STDIN");
ok(defined $Forks::Super::CHILD_STDIN{$pid}, "CHILD_STDIN value defined");
ok(!defined $Forks::Super::CHILD_STDOUT{$pid}, "CHILD_STDOUT value not defined");
ok(defined $Forks::Super::CHILD_STDERR{$pid}, "CHILD_STDERR value defined");
$t = time;
@out = ();
@err = ();
while (time < $t+12) {
  my @data = Forks::Super::read_stdout($pid);
  push @out, @data if @data>0 and $data[0] ne "";

  @data = Forks::Super::read_stderr($pid);
  push @err, @data if @data>0 and $data[0] ne "";
}
ok(@out == 0, "received no output from child");
@err = grep { !/alarm\(\) not available/ } @err;

if (@err != 2) {
  print STDERR "\ntest read stderr: failure imminent.\n";
  print STDERR "Expecting two lines but what we get is:\n";
  my $i;
  print STDERR map { ("Error line ", ++$i , ": $_") } @err;
  print STDERR "\n";
  print STDERR "Rerunning read_stderr test with debugging on ...\n";

  # retest with debugging -- let's see if we can figure out what's going on
  $Forks::Super::DEBUG = 1;
  ($z,$pid) = &read_stderr_test;
  $t = time;
  $i = 0;
  @err = ();
  while (time < $t+12) {
    my @data = Forks::Super::read_stderr($pid);
    push @err, @data if @data>0 and $data[0] ne "";
  }
  print STDERR "Standard error from retest:\n";
  print STDERR map { ("Error line ", ++$i, ": $_") } @err;
  @err = grep { !/repeater:/ && !/alarm/ } @err;
}


ok(@err == 2, "received 2 lines from child stderr");
ok($err[0] =~ /the message is/, "got expected first line from child error");
ok($err[-1] =~ /a test/, "got expected second line from child error");
waitall; 
$Forks::Super::DEBUG = 0;

##################################################

#
# a proof-of-concept: pass strings to a child 
# and receive back the checksums
#

sub compute_checksums_in_child {
  sleep 5;
  while (<STDIN>) {
    s/\s+$//;
    last if $_ eq "__END__";
    print "$_\\", unpack("%32C*",$_)%65535,"\n";
  }
}

my @pids = ();
for (my $i=0; $i<4; $i++) {
  push @pids, fork { sub => \&compute_checksums_in_child,
		       get_child_stdin => 1, get_child_stdout => 1 };
}
my @data = (@INC,%INC,%!);
my (@pdata, @cdata);
for (my $i=0; $i<@data; $i++) {
  Forks::Super::write_stdin $pids[$i%4], "$data[$i]\n";
  push @pdata, sprintf("%s\\%d\n", $data[$i], unpack("%32C*",$data[$i])%65535);
}
Forks::Super::write_stdin($_,"__END__\n") for @pids;
waitall;
foreach (@pids) {
  push @cdata, Forks::Super::read_stdout($_);
}
ok(@pdata == @cdata);
@pdata = sort @pdata;
@cdata = sort @cdata;
my $pc_equal = 1;
for (my $i=0; $i<@pdata; $i++) {
  $pc_equal=0 if $pdata[$i] ne $cdata[$i];
}
ok($pc_equal);


__END__
