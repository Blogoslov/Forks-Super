use Forks::Super ':test';
use Test::More;
use strict;
use warnings;
$| = 1;

{
  plan tests => 12;
}

#if (Forks::Super::CONFIG("alarm")) {
#  alarm 60;$SIG{ALRM} = sub { die "Timeout $0 ran too long\n" };
#}

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
    while ($_ = defined getsockname(STDIN) ? Forks::Super::_read_socket(undef,*STDIN,0) : <STDIN>) {
    #while (<STDIN>) {
      if ($Forks::Super::DEBUG) {
	$input = substr($_,0,-1);
	$input_found = 1;
	Forks::Super::debug("repeater: read \"$input\" on STDIN/",
			    fileno(STDIN));
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
  }
}

#######################################################

my $pid = fork { sub => \&repeater, timeout => 10, args => [ 3, 1 ], 
		 child_fh => "in,out,err,pipe" };

ok(isValidPid($pid), "pid $pid valid");
ok(defined $Forks::Super::CHILD_STDIN{$pid} 
   && defined fileno($Forks::Super::CHILD_STDIN{$pid}),
   "found stdin fh");
ok(defined $Forks::Super::CHILD_STDOUT{$pid} 
   && defined fileno($Forks::Super::CHILD_STDOUT{$pid}),
   "found stdout fh");
ok(defined $Forks::Super::CHILD_STDERR{$pid} 
   && defined fileno($Forks::Super::CHILD_STDERR{$pid}),
   "found stderr fh");
ok(-p $Forks::Super::CHILD_STDIN{$pid} &&
   -p $Forks::Super::CHILD_STDOUT{$pid} &&
   -p $Forks::Super::CHILD_STDERR{$pid},
   "STDxxx handles are pipes");
my $msg = sprintf "%x", rand() * 99999999;
my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
ok($z > 0, "print to child stdin successful");
my $t = time;
my $fh_out = $Forks::Super::CHILD_STDOUT{$pid};
my $fh_err = $Forks::Super::CHILD_STDERR{$pid};
my (@out,@err);
while (time < $t+8) {
  push @out, Forks::Super::read_stdout($pid);
  push @err, Forks::Super::read_stderr($pid);
  sleep 1;
}
Forks::Super::close_fh($pid);

ok(@out == 3, scalar @out . " == 3 lines from STDOUT   [\n @out ]");

@err = grep { !/alarm\(\) not available/ } @err;  # exclude warning to child STDERR
ok(@err == 1, scalar @err . " == 1 line from STDERR\n" . join $/,@err);

ok($out[0] eq "0:$msg\n", "got Expected first line from child output");
ok($out[1] eq "1:$msg\n", "got Expected second line from child output");
ok($out[2] eq "2:$msg\n", "got Expected third line from child output");
ok($err[-1] eq "$msg\n", "got Expected line from child error");

my $r = waitall 10;
