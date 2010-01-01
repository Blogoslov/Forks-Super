use Forks::Super ':test';
use Test::More tests => 26;
use strict;
use warnings;

#
# test forking a child process and invoking a Perl subroutine
#


#
# a mock internal command that can
#    * delay before returning
#    * produce simple output to stdout or to file
#    * collect simple env info like PID
#    * exit with arbitrary status
#
# See t/external-command.pl
#
sub internal_command {
  my (@args) = @_;
  foreach my $arg (@args) {
    my ($key,$val) = split /=/, $arg;
    if ($key eq "--output" or $key eq "-o") {
      open(OUT, ">", $val);
      select OUT;
      $| = 1;
    } elsif ($key eq "--echo" or $key eq "-e") {
      print $val, " ";
    } elsif ($key eq "--ppid" or $key eq "-p") {
      my $pid = $$;
      print $pid, " ";
    } elsif ($key eq "--sleep" or $key eq "-s") {
      sleep $val || 1;
    } elsif ($key eq "--exit" or $key eq "-x") {
      select STDOUT;
      close OUT;
      Forks::Super::child_exit $val || 0;
    }
  }
  select STDOUT;
  close OUT;
}





# test  fork  sub => $
#
# XXX - not satisfied with this. Should be able to use 'internal_command' and the
#       fork routine should be able to attach it to the calling package.
#

open(LOCK, ">>", "t/out/.lock-t12");
flock LOCK, 2;

# test fork => $::

unlink "t/out/test2";
my $pid = fork { sub => 'main::internal_command',
		args => [ "-o=t/out/test2", "-e=Hello,", 
                          "-e=Wurrled", "-p" ] };
ok(isValidPid($pid), "fork to \$qualified::subroutineName successful, pid=$pid");
my $p = wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child status \$? == 0");
my $z = do { my $fh; open($fh, "<", "t/out/test2"); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
my $target_z = "Hello, Wurrled $pid";
ok($z eq $target_z, 
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test fork => $

unlink "t/out/test2";
$pid = fork { sub => 'internal_command',
	      args => [ "-o=t/out/test2", "-e=Hello,", 
                        "-e=Wurrled", "-p" ] };
ok(isValidPid($pid), "fork to \$subroutineName successful, pid=$pid");
$p = wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child status \$? == 0");
$z = do { my $fh; open($fh, "<", "t/out/test2"); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
$target_z = "Hello, Wurrled $pid";
ok($z eq $target_z, 
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test  fork  sub => \&

unlink "t/out/test2";
$pid = fork { sub => \&internal_command,
		args => ["-o=t/out/test2", "-e=Hello,", "-e=Wurrled", "-p" ] };
ok(isValidPid($pid), "fork to \\\&subroutine successful");
$p = wait;
ok($pid == $p, "wait reaped child $pid == $p");
ok($? == 0, "child status \$? == 0");
$z = do { my $fh; open($fh, "<", "t/out/test2"); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
$target_z = "Hello, Wurrled $pid";
ok($z eq $target_z,
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test fork to anonymous sub

unlink "t/out/test2";
$pid = fork { sub => sub { my (@x) = @_;
			   open(T, ">", "t/out/test2");
			   print T "@x - $$\n";
			   close T;
			   exit 1;	
			 },
			   args => [ "Hello", "-", "World" ] };
ok(isValidPid($pid), "fork to anonymous sub successful");
$p = wait;
ok($?>>8 == 1, "child status $? \$? != 0");
ok($pid == $p, "wait reaped child $pid == $p");
$z = do { my $fh; open($fh, "<", "t/out/test2"); my $zz = join '', <$fh>; close $fh; $zz };
$z =~ s/\s+$//;
$target_z = "Hello - World - $pid";
ok($z eq $target_z,
	"child produced child output \'$z\' vs. \'$target_z\'");

#############################################################################

# test that timing of reap is correct

$pid = fork { sub => sub { sleep 3 } };
ok(isValidPid($pid), "fork to sleepy sub ok");
my $t = time;
$p = wait;
$t = time - $t;
ok($p == $pid, "wait on sleepy sub ok");
ok($t >= 3 && $t <= 4, "background sub ran ${t}s, expected 3-4s");

##################################################################

# test exit status

$pid = fork { sub => sub { exit 7 } };
ok(isValidPid($pid), "fork to false sub ok");
$p = Forks::Super::wait;
ok($p == $pid, "wait on false sub ok");
ok($?>>8 == 7, "captured correct non-zero status");
ok($Forks::Super::ALL_JOBS{$pid}->{status} == 7 << 8,
  $Forks::Super::ALL_JOBS{$pid}->toString() . " what's the deal?");

##################################################################

$pid = fork { sub => sub {} };
ok(isValidPid($pid), "fork to trivial sub ok");
$p = wait;
ok($? == 0, "captured correct zero status from trivial sub");
ok($p == $pid, "wait on trivial sub ok");

close LOCK;
