#
# recommend.pl
#
# check out what modules are available on your system.
# recommend some modules to install that might be
# helpful with setting CPU affinities.
#

sub check_module {
  my $module = shift;
  eval "require $module";

  if (!$@) {
    my $version_name = $module . "::VERSION";
    my $version = ${$version_name};
    if (defined $version) {
        return $version;
    }
  }

  return !$@;
}

sub get_recommendations {
  my $system = shift;
  my %recommendations = ();
  if ($system =~ /MSWin32/ || $system =~ /cygwin/) {
    $recommendations{"Win32::API"} = 0 unless check_module("Win32::API");
    $recommendations{"Win32::Process"} = 0 unless check_module("Win32::Process");
  } elsif ($system =~ /bsd/i) {
    $recommendations{"BSD::Process::Affinity"} = 0 
      unless check_module("BSD::Process::Affinity");
  } elsif ($system =~ /solaris/i) {
    $recommendations{"Solaris::Lgrp"} = 0
      unless check_module("Solaris::Lgrp");
  }

  return %recommendations;
}

unless (caller) {
  my %recommendations = get_recommendations($ARGV[0] || $^O);
  if (0 == scalar keys %recommendations) {

    print "$0 does not have any recommendations for this system.\n";
    exit 0;

  } else {

    print "$0 has determined that you could benefit from installing\n";
    print "these additional modules on your system:\n\n";

    foreach my $module (sort keys %recommendations) {
      printf "\t%-25s => min. version %s\n", $module, $recommendations{$module};
    }
    my $n = scalar keys %recommendations;
    exit $n > 255 ? 255 : $n;
  }
}
