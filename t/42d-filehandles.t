use Forks::Super ':test';
use Test::More tests => 6;
use Carp;
use strict;
use warnings;





##################################################################
#
# this particular test is a failure point in v0.35 through v0.39,
# mainly x86_64-linux systems. It seems to be fixed since 0.40, 
# when we try to use  Time::HiRes::setitimer  to trigger queue
# checks instead of using a separate process which must occasionally
# be restarted and killed.
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
  ($ENV{HOME}) = $ENV{HOME} =~ /(.*)/;
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
  # print $POOR_MANS_SORT "use strict; use warnings;\n";
  print $POOR_MANS_SORT "print sort <>\n";
  close $POOR_MANS_SORT;
  @cmd = ($^X, "t/poorsort.pl");
}

my $input = join("\n", qw(the quick brown fox jumps over the lazy dog)) . "\n";
my $output = '';
my $error = "overwrite me\n";

$Forks::Super::ON_BUSY = "queue";

my $pid = fork { 
	stdin => $input, 
	stdout => \$output, 
	stderr => \$error, 
        cmd => \@cmd, 
	delay => 2 
};
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
$pid = fork {
	stdin => \@input , 
	stdout => \$output, 
	exec => \@cmd, 
	delay => 2 
};
ok($output eq $orig_output, "output not updated until child is complete.");
waitpid $pid, 0;
my @output = split /\n/, $output;
ok($output[0] eq "bike 2" && $output[2] eq "car 4" && $output[3] eq "gun 6",
"read input from ARRAY ref");
waitall;

