use lib qw(blib/lib blib/arch);
use Sys::CpuAffinity;

# read Sys::CpuAffinity source code to get list of method names
# for counting processors, getting/setting cpu affinity

open my $G, "<", $INC{"Sys/CpuAffinity.pm"} or die $!;
while (<$G>) {
  next unless /^sub _/;
  next if /XXX/;        # method still under development
  if (/^sub _setAffinity_with_(\S+)/) {
    push @SET, $1;
  } elsif (/^sub _getAffinity_with_(\S+)/) {
    push @GET, $1;
  } elsif (/^sub _getNumCpus_from_(\S+)/) {
    push @NCPUS, $1;
  }
}
close $G;

sub inventory::getAffinity { return sort {lc $a cmp lc $b} @GET }
sub inventory::setAffinity { return sort {lc $a cmp lc $b} @SET }
sub inventory::getNumCpus { return sort {lc $a cmp lc $b} @NCPUS }

unless (caller) {
  # running t/inventory.pl as standalone script

  print "Count active processors with:\n\t'";
  print join "',\n\t'", @NCPUS;

  print "'\n\nGet affinity with:\n\t'";
  print join "',\n\t'", @GET;

  print "'\n\nSet affinity with:\n\t'";
  print join "',\n\t'", @SET;

  print "'\n\n";
}

1;
