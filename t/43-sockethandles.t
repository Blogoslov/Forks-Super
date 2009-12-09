use Forks::Super ':test';
use Test::More tests => 34;
use strict;
use warnings;
if (Forks::Super::CONFIG("alarm")) {
  alarm 60;$SIG{ALRM} = sub { die "Timeout $0 ran too long\n" };
}

#
# test whether a parent process can have access to the
# STDIN, STDOUT, and STDERR filehandles of a child
# process. This features allows for communication
# between parent and child processes.
#

# this is a subroutine that copies STDIN to STDOUT and optionally STDERR
sub repeater {
  Forks::Super::debug("repeater: method beginning") if $Forks::Super::DEBUG;

  my ($n, $e) = @_;
  my $end_at = time + 6;
  my ($input_found, $input) = 1;
  my $curpos;
  local $!;

  binmode STDOUT;  # for MSWin32 compatibility
  binmode STDERR;  # has no bad effect on other OS
  Forks::Super::debug("repeater: ready to read input") if $Forks::Super::DEBUG;
  while (time < $end_at) {
    # use idiom for "cantankerous" IO implementations -- see perldoc -f seek
    while (defined ($_ = Forks::Super::_read_socket(undef, *STDIN, 0))) {
      if ($Forks::Super::DEBUG) {
	$input = substr($_,0,-1);
	$input_found = 1;
	Forks::Super::debug("repeater: read \"$input\" on STDIN/",fileno(STDIN));
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
    }
    if ($Forks::Super::DEBUG && $input_found) {
      $input_found = 0;
      Forks::Super::debug("repeater: no input");
    }
    Forks::Super::pause();
  }
  if (0 && $Forks::Super::DEBUG) { # f_in can't be read in socket context
    my $f_in = $Forks::Super::Job::self->{fh_config}->{f_in};
    Forks::Super::debug("repeater: time expired. Not processing any more input");
    Forks::Super::debug("input was from file: $f_in");
    open(F_IN, "<", $f_in);
    while (<F_IN>) {
      s/\s+$//;
      Forks::Super::debug("    input $.: $_");
    }
    close F_IN;
  }
}

#######################################################

my $pid = fork { sub => \&repeater, timeout => 10, args => [ 3, 1 ], 
		 child_fh => "in,out,err,socket" };

ok(isValidPid($pid), "pid $pid valid");
ok(defined $Forks::Super::CHILD_STDIN{$pid} && defined fileno($Forks::Super::CHILD_STDIN{$pid}),"found stdin fh");
ok(defined $Forks::Super::CHILD_STDOUT{$pid} && defined fileno($Forks::Super::CHILD_STDOUT{$pid}),"found stdout fh");
ok(defined $Forks::Super::CHILD_STDERR{$pid} && defined fileno($Forks::Super::CHILD_STDERR{$pid}),"found stderr fh");
ok(defined getsockname($Forks::Super::CHILD_STDIN{$pid}) &&
   defined getsockname($Forks::Super::CHILD_STDOUT{$pid}) &&
   defined getsockname($Forks::Super::CHILD_STDERR{$pid}), "STDxxx handles are socket handles");
my $msg = sprintf "%x", rand() * 99999999;
my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
shutdown($fh_in, 1) || close $fh_in;
ok($z > 0, "print to child stdin successful");
my $t = time;
my $fh_out = $Forks::Super::CHILD_STDOUT{$pid};
my $fh_err = $Forks::Super::CHILD_STDERR{$pid};
my (@out,@err);
while (time < $t+10) {
  push @out, Forks::Super::read_stdout($pid);
  push @err, Forks::Super::read_stderr($pid);
  sleep 1;
}
shutdown($fh_out, 2) || close $fh_out;
shutdown($fh_err, 2) || close $fh_err;

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
		child_fh => [ "in", "out", "join", "socket" ] };
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
shutdown($Forks::Super::CHILD_STDIN{$pid},2) || close $Forks::Super::CHILD_STDIN{$pid};
shutdown($Forks::Super::CHILD_STDOUT{$pid},2) || close $Forks::Super::CHILD_STDOUT{$pid};
shutdown($Forks::Super::CHILD_STDERR{$pid},2) || close $Forks::Super::CHILD_STDERR{$pid};

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
		  child_fh => "in,err,socket" };

  my $z = 0;
  if (isValidPid($pid)) {
    my $msg = sprintf "the message is %x", rand() * 99999999;
    my $pid_stdin_fh = $Forks::Super::CHILD_STDIN{$pid};

    $z = print $pid_stdin_fh "$msg\n";
    if ($Forks::Super::DEBUG) {
      Forks::Super::debug("Printed \"$msg\\n\" to child stdin ($pid). Result:$z");
    }
    sleep 1;
    $z = print $pid_stdin_fh "That was a test\n";
    if ($Forks::Super::DEBUG) {
      Forks::Super::debug("Printed \"That was a test\\n\" to child stdin ($pid). Result:$z");
    }
    shutdown($Forks::Super::CHILD_STDIN{$pid}, 1) || close $Forks::Super::CHILD_STDIN{$pid};
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
  binmode STDOUT;
  for (;;) {
    $_ = <STDIN>;
    if (not defined $_) {
      Forks::Super::pause();
      next;
    }
    s/\s+$//;
    last if $_ eq "__END__";
    print "$_\\", unpack("%32C*",$_)%65535,"\n";
  }
}

my @pids = ();
for (my $i=0; $i<4; $i++) {
  push @pids, fork { sub => \&compute_checksums_in_child, timeout => 20,
			child_fh => "in,out,socket" };
}
my @data = (@INC,%INC,keys(%!),keys(%ENV));
my (@pdata, @cdata);
for (my $i=0; $i<@data; $i++) {
  print {$Forks::Super::CHILD_STDIN{$pids[$i%4]}} "$data[$i]\n";
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
  $pc_equal=0 if $pdata[$i] ne $cdata[$i] && print "$i: $pdata[$i] /// $cdata[$i] ///\n";
}
ok($pc_equal);


__END__
