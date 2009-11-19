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

my @cmd = ("perl", "t/external-command.pl", "-s=5", "-y=2");
my $pid = fork { cmd => [ @cmd ], timeout => 10,
		get_child_stdin => 1, get_child_stdout => 1, 
                get_child_stderr => 1 };

ok(_isValidPid($pid));
ok(defined $Forks::Super::CHILD_STDIN{$pid});
ok(defined $Forks::Super::CHILD_STDOUT{$pid});
ok(defined $Forks::Super::CHILD_STDERR{$pid});
my $msg = sprintf "%x", rand() * 99999999;
my $fh_in = $Forks::Super::CHILD_STDIN{$pid};
my $z = print $fh_in "$msg\n";
close $fh_in;
ok($z > 0);
my $t = time;
my $fh_out = $Forks::Super::CHILD_STDOUT{$pid};
my $fh_err = $Forks::Super::CHILD_STDERR{$pid};
my (@out, @err) = ();
while (time < $t+10) {
  push @out, <$fh_out>;
  push @err, <$fh_err>;
  sleep 1;
  seek $fh_out,0,1;
  seek $fh_err,0,1;

# print "\@out:\n------\n@out\n\@err:\n-------\n@err\n";
}

ok(@out == 3, scalar @out . " == 3 lines from STDOUT");
ok(@err == 1, scalar @err . " == 1 line from STDERR");
ok($out[0] eq "$msg\n");
ok($out[1] eq "$msg\n");
ok($out[2] eq "\n");
ok($err[0] =~ /received message $msg/);
waitall;

#######################################################

# test join, read_stdout

$pid = fork { cmd => [ @cmd ], timeout => 10,
	    get_child_stdin => 1, get_child_stdout => 1,
            join_child_stderr => 1 };
ok(_isValidPid($pid), "started job with join");

$msg = sprintf "the message is %x", rand() * 99999999;
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "$msg\n";
ok($z > 0);
ok(defined $Forks::Super::CHILD_STDIN{$pid});
ok(defined $Forks::Super::CHILD_STDOUT{$pid});
ok(defined $Forks::Super::CHILD_STDERR{$pid});
ok($Forks::Super::CHILD_STDOUT{$pid} eq $Forks::Super::CHILD_STDERR{$pid}, "child stdout and stderr go to same fh");
$t = time;
@out = ();
while (time < $t+10) {
  my $line = Forks::Super::read_stdout($pid);
  last if not defined $line;
  push @out, $line if length $line;
}
ok(@out == 4);
ok($out[0] =~ /the message is/);
ok($out[0] eq "$msg\n");
ok($out[1] eq "$msg\n");
ok($out[2] eq "received message $msg\n");
ok($out[3] eq "\n");
waitall; 

#######################################################

# test read_stderr

$pid = fork { cmd => [ @cmd , "-y=3" ], timeout => 12,
	    get_child_stdin => 1, get_child_stdout => 0, 
            get_child_stderr => 1 };
ok(_isValidPid($pid), "started job with join");

$msg = sprintf "the message is %x", rand() * 99999999;
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "$msg\n";
$z = print {$Forks::Super::CHILD_STDIN{$pid}} "That was a test\n";
ok($z > 0);
ok(defined $Forks::Super::CHILD_STDIN{$pid});
ok(not defined $Forks::Super::CHILD_STDOUT{$pid});
ok(defined $Forks::Super::CHILD_STDERR{$pid});
$t = time;
@out = ();
@err = ();
while (time < $t+10) {
  my @data = Forks::Super::read_stdout($pid);
  push @out, @data if @data>0 and $data[0] ne "";

  @data = Forks::Super::read_stderr($pid);
  push @err, @data if @data>0 and $data[0] ne "";
}
ok(@out == 0);
ok(@err == 2);
ok($err[0] =~ /received message $msg/);
ok($err[1] =~ /a test/);
waitall; 

##################################################

# get filehandles by job ID

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
