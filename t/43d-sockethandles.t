use Forks::Super ':test';
use Test::More tests => 2;
use strict;
use warnings;

$SIG{ALRM} = sub { die "Timeout $0 ran too long\n" };
eval { alarm 150 };

#
# test whether a parent process can have access to the
# STDIN, STDOUT, and STDERR filehandles of a child
# process. This features allows for communication
# between parent and child processes.
#

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
  # v0.33: list context may be supported
  push @pids, scalar fork { sub => \&compute_checksums_in_child, timeout => 20,
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
ok(@pdata > 0 && @pdata == @cdata, "$$\\parent & child processed "
   .(scalar @pdata)."/".(scalar @cdata)." strings");
@pdata = sort @pdata;
@cdata = sort @cdata;
my $pc_equal = 1;
for (my $i=0; $i<@pdata; $i++) {
  $pc_equal=0 if $pdata[$i] ne $cdata[$i] && print "$i: $pdata[$i] /// $cdata[$i] ///\n";
}
ok($pc_equal, "parent/child agree on output");

#######################################################################

# ok(1, "stdin/stdout/stderr test with socket not ready");

if (0) {

#
# XXX - needs work
# 

my $input = "Hello world\n";
my $output = "";
my $error = "overwrite me!";
my $pid = fork { 
  stdin => $input, stdout => \$output, stderrx => \$error, child_fh => "sock",
    sub => sub {
      sleep 1;
      while(<STDIN>) {
	print STDERR "Got input: $_";
	chomp;
	my $a = reverse $_;
	print $a, "\n";
      }
    }, debug => 1 };
ok($output eq "" && $error =~ /overwrite/, 
   "output/error not updated until child is complete");
waitpid $pid, 0;
ok($output eq "dlrow olleH\n", "updated output from stdout");
ok($error !~ /overwrite/, "error ref was overwritten");
ok($error eq "Got input: $input");

my @input = ("Hello world\n", "How ", "is ", "it ", "going?\n");
my $orig_output = $output;
$pid = fork { stdin => \@input , stdout => \$output, child_fh => "sock",
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
ok($output eq "11dlrow olleH\n16?gniog ti si woH\n", 
   "read input from ARRAY ref");

}

use Carp;$SIG{SEGV} = sub { Carp::cluck "XXXXXXX Caught SIGSEGV during cleanup of $0 ...\n" };

eval { alarm 0 };