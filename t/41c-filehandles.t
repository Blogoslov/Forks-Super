use Forks::Super ':test';
use Test::More tests => 2;
use strict;
use warnings;

Forks::Super::Debug::_use_Carp_Always();

$SIG{ALRM} = sub { die "Timeout $0 ran too long\n" };
eval { alarm 150 };

##################################################

#
# a proof-of-concept: pass strings to a child 
# and receive back the checksums
#

sub compute_checksums_in_child {
  sleep 5;
  while (<STDIN>) {
    s/\s+$//;
    last if $_ eq "__END__";
    print "$_\\", unpack("%32C*",$_)%65535,"\n";
  }
}

my @pids = ();
for (my $i=0; $i<4; $i++) {
  push @pids, 
    fork { 
      sub => \&compute_checksums_in_child, 
      child_fh => "in,out" 
    };
}
my @data = (@INC,%INC,%!);
my (@pdata, @cdata);
for (my $i=0; $i<@data; $i++) {
  Forks::Super::write_stdin $pids[$i%4], "$data[$i]\n";
  push @pdata, sprintf("%s\\%d\n", $data[$i], unpack("%32C*",$data[$i])%65535);
}
Forks::Super::write_stdin($_,"__END__\n") for @pids;
waitall;
foreach (@pids) {
  push @cdata, Forks::Super::read_stdout($_);
}
ok(@pdata == @cdata, "Master/slave produced ".scalar @pdata."/".scalar @cdata." lines"); ### 21 ###

if (@pdata != @cdata) {
  print STDERR "\@pdata: @pdata[0..100]\n";
  print STDERR "--------------\n\@cdata: @cdata[0..100]\n";
}

@pdata = sort @pdata;
@cdata = sort @cdata;
my $pc_equal = 1;
for (my $i=0; $i<@pdata; $i++) {
  if (!defined $pdata[$i] || !defined $cdata[$i] 
	|| $pdata[$i] ne $cdata[$i]) {
    $pc_equal=0 
  }
}
ok($pc_equal, "master/slave produced same data"); ### 22 ###

##########################################################

eval { alarm 0 };