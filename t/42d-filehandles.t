use Forks::Super ':test';
use Test::More tests => 6;
use Carp;
use strict;
use warnings;





##################################################################
#
# this particular test is a failure point in v0.35 through v0.38
# In about 10-20% of CPAN tester results,
#     -- all 6 tests are ok
#     -- the exit code of the test is 2
#        From test summary report: (Wstat: 512 Tests: 6 Failed: 0)
#     -- or sometimes the "status" is 139 (SIGSEGV + core dump)
#     -- affects Linux and netbsd more than other archs
#     -- affects archname =~ /x86_64-linux/ more than other archs
#
# The CPAN testers seem to reproduce it pretty easily, but
# I have not been able to (even though I have x86_64-linux
# and x86_64-linux-thread-multi versions of perl.
#     -- Is there a stray SIGINT somewhere?
#        -- v0.39 fork with timeout now sends SIGTERM instead of SIGINT.
#           if we now observe spurious exit code 15, this is a likely
#           culprit
#     -- Does perl interpreter exit with code 2 under some conditions?
# 
# <XXX>This may be a consequence of the SIGCHLD handler running after
# the END queue call has started. In v0.38 we disable the SIGCHLD handler
# in the END queue -- we'll see if that helps.</XXX> No, that didn't help.
#
# In v0.39 the default is to use SIGTERM instead of SIGINT to timeout
# a child. If the problem persists but the exit code becomes 15 instead
# of 2, then the child killer is a likely culprit.
#
##################################################################




#
# test whether the parent can have access to the
# STDIN, STDOUT, and STDERR filehandles from a
# child process when the child process uses
# the "cmd" option to run a shell command.
#
if (${^TAINT}) {
  $ENV{PATH} = "";
  ($^X) = $^X =~ /(.*)/;
}

Forks::Super::Debug::_use_Carp_Always();

##########################################################

# exercise stdout, stdin, stderr 
my @cmd;

if (-x '/bin/sort') {
  @cmd = ("/bin/sort");
} elsif (-x '/usr/bin/sort') {
  @cmd = ("/usr/bin/sort");
} else {
  open(my $POOR_MANS_SORT, '>', 't/poorsort.pl');
  print $POOR_MANS_SORT "#!$^X\n";
  print $POOR_MANS_SORT "print sort <>\n";
  close $POOR_MANS_SORT;
  @cmd = ($^X, "t/poorsort.pl");
}

my $input = join("\n", qw(the quick brown fox jumps over the lazy dog)) . "\n";
my $output = '';
my $error = "overwrite me\n";

$Forks::Super::ON_BUSY = "queue";

my $pid = fork { stdin => $input, stdout => \$output, stderr => \$error, 
              cmd => \@cmd, delay => 2 };
ok($output eq '' && $error =~ /overwrite/,
   "$$\\output/error not updated until child is complete");
waitpid $pid, 0;
ok($output eq "brown\ndog\nfox\njumps\nlazy\nover\nquick\nthe\nthe\n",
   "updated output from stdout\ncmd \"@cmd\", output:\n$output");
ok(!$error || $error !~ /overwrite/, "error ref was overwritten");
ok($error !~ /overwrite/, "error ref was overwritten/\$error=$error");

my @input = ("tree 1\n","bike 2\n","camera 3\n",
	     "car 4\n","hand 5\n","gun 6\n");
my $orig_output = $output;
$pid = fork { stdin => \@input , stdout => \$output, 
	      exec => \@cmd, delay => 2 };
ok($output eq $orig_output, "output not updated until child is complete.");
waitpid $pid, 0;
my @output = split /\n/, $output;
ok($output[0] eq "bike 2" && $output[2] eq "car 4" && $output[3] eq "gun 6",
"read input from ARRAY ref");
waitall;

use Carp;$SIG{SEGV} = sub {
  Carp::cluck "Caught SIGSEGV during cleanup of $0 ...\n"
};

