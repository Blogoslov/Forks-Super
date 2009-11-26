#! perl
# $^X external-command.pl [options]
#
# We don't know what OS and environment we are testing on.
# The only external program we can be confident about having
# is perl, so when an external program is needed to test
# something, we'll use a perl script.
#
# Depending on the command line arguments provided, this script
# is capable of mocking an external command by running for a certain
# amount of time, producing simple output to a file, determining
# environment like the PPID, and exiting with an arbitrary exit code.
#
#   -s=n          go to sleep for <n> seconds
#   -e=msg        writes the msg to standard output or output
#   -o=file       redirect standard output to file
#   -p            outputs the parent PID
#   -x=z          exit with code <z>
#   -y=n          print line from STDIN <n> times to STDOUT, once to STDERR
#
#
# Examples:
#
#   $^X t/external-command.pl -o=t/out/test -e=Hello, -e=Whirled -p -x=0
#

use strict;

$| = 1;
foreach my $arg (@ARGV) {
  my ($key,$val) = split /=/, $arg;
  if ($key eq "--output" or $key eq "-o") {
    open(OUT, ">", $val);
    select OUT;
    $| = 1;
  } elsif ($key eq "--echo" or $key eq "-e") {
    print $val, " ";
  } elsif ($key eq "--ppid" or $key eq "-p") {
    # On MSWin32, getppid() is broken. 
    my $pid = $^O eq "MSWin32" ? $ENV{_FORK_PPID} : getppid();
    print $pid, " ";
  } elsif ($key eq "--sleep" or $key eq "-s") {
    sleep $val || 1;
  } elsif ($key eq "--exit" or $key eq "-x") {
    exit $val || 0;
  } elsif ($key eq "--input" or $key eq "-y") {
    my $y = <STDIN>;
    while ($val-- > 0) {
      print $y;
    }
    print STDERR "received message $y";
  }
}
END {
  print OUT "\n";
  print STDOUT "\n";

  close OUT;
  close STDOUT;
  close STDERR;
}

exit 0;
