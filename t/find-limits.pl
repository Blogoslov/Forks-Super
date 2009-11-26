use strict;
use warnings;

###############################################################
#
# in preparation for the tests in t/32-stress-test.t, discover
# the maximum number of forks that are allowed on this system
#
###############################################################
#
# Cygwin note: this script can trigger a five-minute delay
# followed by a "WFSO timed out after longjmp" error message.
# When the parent runs out of resources, it will fail to copy
# its data (heap, stack, etc.) to the new child process, and
# fail to signal the child process to wake up. The child will
# wake up by itself in five minutes, but without valid data it
# will trigger the above WFSO error. I don't think this 
# affects the testing of the module except to make it take
# a few extra minutes to run.
#
###############################################################

my $limits_file = $ARGV[0] || "t/out/limits.$^O.$]";
if (-f $limits_file) {
  unlink $limits_file;
}

undef $@;
my $r = eval {
  for (my $i=0; $i<200; $i++) {
    undef $@;
    my $pid;
    eval { $pid = fork() }; # CORE::fork, not Forks::Super::fork
    if ($@ || !defined $pid) {
      print STDERR "$^O-$] cannot fork more than $i child processes.\n";
      1 while wait > -1;
      exit 0;
    } elsif ($pid == 0) {
      sleep 15;
      exit 0;
    }
    if ($i > 1) {
      open(L, ">", $limits_file);
      print L "maxfork:$i\n";
      close L;
    }
  }
  print STDERR "$^O-$] successfully forked 200 processes.\n";
  1 while wait > -1;
};
print "Result: $r / $@\n";
