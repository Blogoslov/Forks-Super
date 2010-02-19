use Forks::Super ':test';
use Test::More tests => 28;
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

# this is a subroutine that copies STDIN to STDOUT and optionally STDERR
sub repeater {
  Forks::Super::debug("repeater: method beginning") if $Forks::Super::DEBUG;

  my ($n, $e) = @_;
  my $end_at = time + 6;
  my ($input_found, $input) = 1;
  local $!;

  Forks::Super::debug("repeater: ready to read input") if $Forks::Super::DEBUG;
  while (time < $end_at) {
    while (defined ($_ = <STDIN>)) {
      if ($Forks::Super::DEBUG) {
	$input = substr($_,0,-1);
	$input_found = 1;
	Forks::Super::debug("repeater: read \"$input\" on STDIN/",fileno(STDIN));
      }
      if ($e) {
        print STDERR $_;
	if ($Forks::Super::DEBUG) {
	  Forks::Super::debug("repeater: wrote \"$input\" to STDERR/",
			      fileno(STDERR));
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
    seek STDIN, 0, 1;
  }
  if ($Forks::Super::DEBUG) {
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
  close STDOUT;
  close STDERR;
}

#######################################################

my $pid = fork { sub => \&repeater, timeout => 10, args => [ 3, 1 ], 
		   child_fh => "all" };

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

@err = grep { !/alarm\(\) not available/ } @err; # exclude warning to child STDERR
ok(@err == 1, scalar @err . " == 1 line from STDERR\n" . join $/,@err);

ok($out[0] eq "0:$msg\n", "got expected first line from child output");
ok($out[1] eq "1:$msg\n", "got expected second line from child output");
ok($out[2] eq "2:$msg\n", "got expected third line from child output");
ok($err[-1] eq "$msg\n", "got expected line from child error");
waitall;

#######################################################
# test read_stderr -- this is the last significant failure point from 0.08
# the usual error is that @err contains one line instead of two
# let's retest with debugging if we detect that this test is going to fail ...

sub read_stderr_test1 {

  $pid = fork { sub => \&repeater , args => [ 3, 1 ] , timeout => 10,
		child_fh => "in,err" };

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
      Forks::Super::debug("Printed \"That was a test\\n\" to child stdin ($pid).",
                          " Result:$z");
    }
    sleep 1;
    close $Forks::Super::CHILD_STDIN{$pid};
    if ($Forks::Super::DEBUG) {
      Forks::Super::debug("Closed filehandle to $pid STDIN");
    }
  }
  return ($z,$pid);
}

($z,$pid) = &read_stderr_test1;
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
  if ($Forks::Super::DEBUG && defined $data[0]) {
    Forks::Super::debug("Read from child $pid stdout: [ ", @data,  " ]");
  }
  push @out, @data if @data>0 and $data[0] ne "";

  @data = Forks::Super::read_stderr($pid);
  if ($Forks::Super::DEBUG && defined $data[0]) {
    Forks::Super::debug("Read from child $pid stderr: [ ", @data,  " ]");
  }
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
  ($z,$pid) = &read_stderr_test1;
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
  push @pids, fork { sub => \&compute_checksums_in_child, child_fh => "in,out" };
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

##########################################################

# exercise stdout, stdin, stderr 

my $input = "Hello world\n";
my $output = "";
my $error = "overwrite me!";
$pid = fork { stdin => $input, stdout => \$output, stderr => \$error,
		sub => sub {
		  sleep 1;
		  while(<STDIN>) {
		    print STDERR "Got input: $_";
		    chomp;
		    my $a = reverse $_;
		    print $a, "\n";
		  }
		  } };
ok($output eq "" && $error =~ /overwrite/, 
   "output/error not updated until child is complete");
waitpid $pid, 0;
ok($output eq "dlrow olleH\n", "updated output from stdout");
ok($error !~ /overwrite/, "error ref was overwritten");
ok($error eq "Got input: $input");

my @input = ("Hello world\n", "How ", "is ", "it ", "going?\n");
my $orig_output = $output;
$pid = fork { stdin => \@input , stdout => \$output,
		sub => sub {
		  sleep 1;
		  while (<STDIN>) {
		    chomp;
		    my $a = reverse $_;
		    print length($_), $a, "\n";
		  }
		} };
ok($output eq $orig_output, "output not updated until child is complete");
waitpid $pid, 0;
ok($output eq "11dlrow olleH\n16?gniog ti si woH\n", "read input from ARRAY ref");


