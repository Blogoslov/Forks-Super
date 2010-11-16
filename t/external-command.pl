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
# This script is used in tests:
#      t/11-to-command.t
#      t/13-to-exec.t
#      t/40-timeout.t
#      t/42-filehandle.t
#      t/45-userbusy.t
#      t/60-os.t
#      t/63-bg_qx.t
#


use strict;
use warnings;
no warnings;

my $flag_on_error = 0;
my $STATUS=0;
#$SIG{'INT'} = sub { $STATUS=2; die $^O eq 'MSWin32' ? "die INT\n" : "\n";};
$SIG{'HUP'} = sub { $STATUS=1; die $^O eq 'MSWin32' ? "die HUP\n" : "\n";};

END {
  $?=$STATUS if $STATUS;
  if ($flag_on_error) {
    print STDERR "FLAG $?\n";
  }
  print OUT "\n";
  print STDOUT "\n";
  close OUT;
  close STDOUT;
  close STDERR;
  1;
}

$| = 1;
foreach my $arg (@ARGV) {
  my ($key,$val) = split /=/, $arg;
  if ($key eq '--output' or $key eq '-o') {
    open(OUT, '>', $val);
    select OUT;
    $| = 1;
  } elsif ($key eq '--echo' or $key eq '-e') {
    print $val, ' ';
  } elsif ($key eq '--ppid' or $key eq '-p') {
    # On MSWin32, getppid() is broken. 
    my $ppid = $^O eq 'MSWin32' ? $ENV{_FORK_PPID} : getppid();
    print $ppid, ' ';
  } elsif ($key eq '--pid' or $key eq '-P') {
    my $pid = $^O eq 'MSWin32' ? $ENV{_FORK_PID} : $$;
    print $pid, ' ';
  } elsif ($key eq '--winpid' or $key eq '-W') {
    print $$, ' ';
  } elsif ($key eq '--sleep' or $key eq '-s') {
    sleep $val || 1;
  } elsif ($key eq '--exit' or $key eq '-x') {
    $flag_on_error = 0;
    exit $val || 0;
  } elsif ($key eq '--input' or $key eq '-y') {
    my $y = <STDIN>;
    while ($val-- > 0) {
      print $y;
    }
    print STDERR "received message $y";
  } elsif ($key eq '--newline' or $key eq '-n') {
    print "\n";
  } elsif ($key eq '--flag' or $key eq '-F') {
    $flag_on_error = 1;
  }
}

$flag_on_error = 0;

exit 0;
