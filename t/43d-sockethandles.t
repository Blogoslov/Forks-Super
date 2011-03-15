use Forks::Super ':test';
use Test::More tests => 2;
use strict;
use warnings;

sub _read_socket {
  my $handle = shift;
  return $Forks::Super::Job::Ipc::USE_TIE_SH
	? <$handle>
	: Forks::Super::Job::Ipc::_read_socket($handle, undef, 0);
}


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
  my $count = 0;
  for (;;) {
    $_ = _read_socket(*STDIN);
    if (!defined($_) || $_ eq '') {
      Forks::Super::pause(1.0E-3);
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
  push @pids, 
	scalar fork { 
	  sub => \&compute_checksums_in_child,
	  timeout => 30,
	  child_fh => "in,out,socket"
	};
}
my @data = (@INC,%INC,keys(%!),keys(%ENV),0..99)[0 .. 99];
my (@pdata, @cdata);
for (my $i=0; $i<@data; $i++) {
  #my $fh_i = $Forks::Super::CHILD_STDIN{$pids[$i%4]};
  #my $zzz = print {$fh_i} "$data[$i]\n";
  my $zzz = $pids[$i % 4]->write_stdin("$data[$i]\n");
  push @pdata, sprintf("%s\\%d\n", $data[$i], unpack("%32C*",$data[$i])%65535);
}

for my $pid (@pids) {
  Forks::Super::write_stdin($pid, "__END__\r\n");
  Forks::Super::write_stdin($pid, "__END__\r\n");
  $pid->close_fh('stdin');
}

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
  no warnings 'uninitialized';
  if ($pdata[$i] ne $cdata[$i]) {
    # print "$i: $pdata[$i] /// $cdata[$i] ///\n";
    $pc_equal = 0;
  }
}
ok($pc_equal, "parent/child agree on output");

#######################################################################

use Carp;$SIG{SEGV} = sub {
  Carp::cluck "Caught SIGSEGV during cleanup of $0 ...\n"
};
