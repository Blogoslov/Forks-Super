#
# Forks::Super::Config package - determines what features and
#         modules are available on the current system
#         at run-time.
#
# Some useful system info is expensive to compute so it is
# determined at build time and put into Forks/Super/SysInfo.pm
#


package Forks::Super::Config;
use Forks::Super::Debug qw(debug);
use Forks::Super::SysInfo;
use Carp;
use Exporter;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(CONFIG CONFIG_module);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our (%CONFIG, $IS_TEST, $IS_TEST_CONFIG, %signo);
our $VERSION = $Forks::Super::Debug::VERSION;

sub init {

  %CONFIG = ();
  $CONFIG{filehandles} = 1;

  $IS_TEST = 0;
  $IS_TEST_CONFIG = 0;

  $CONFIG{'Win32::API'} = 0 if $ENV{NO_WIN32_API};

  use Config;
  my $i = 0;
  if (defined $Config::Config{'sig_name'}) {
    %signo = map { $_ => $i++ } split / /, $Config::Config{'sig_name'};
  }

  if (defined $ENV{FORKS_SUPER_CONFIG}) {
    my @cfg_spec = split /,/, $ENV{FORKS_SUPER_CONFIG};
    foreach my $spec (@cfg_spec) {
      if ($spec =~ s/^!//) {
	$CONFIG{$spec} = 0;
      } elsif ($spec =~ s/^\?//) {
	delete $CONFIG{$spec};
	CONFIG($spec);
      } else {
	$CONFIG{$spec} = 1;
      }
    }
  }
}

sub init_child {
  untie $CONFIG{'filehandles'};
  untie %CONFIG;
# unconfig('filehandles');
}

sub unconfig {
  my $module = shift;
  $CONFIG{$module} = 0;
}

sub config {
  my $module = shift;
  $CONFIG{$module} = 1;
}

sub configif {
  my $module = shift;
  return $CONFIG{$module} if defined $CONFIG{$module};
  return config($module);
}

sub deconfig {
  my $module = shift;
  delete $CONFIG{$module};
}

#
# try to import some modules, with the expectation that the module
# might not be available.
#
# Hmmmm. We often run this subroutine from the children, which could mean
# we have to run it for every child.
#
sub CONFIG {
  my ($module, $warn, @settings) = @_;
  if (defined $CONFIG{$module}) {
    return $CONFIG{$module};
  }

  if (substr($module,0,1) eq '/') {
    return $CONFIG{$module} = CONFIG_external_program($module);
  } elsif ($module eq 'filehandles') {
    return $CONFIG{$module} = 1; # available by default
  } else {
    return $CONFIG{$module} =
      CONFIG_module($module,$warn,@settings);
  }
}

sub CONFIG_module {
  my ($module,$warn, @settings) = @_;
  if (defined $CONFIG{$module}) {
    return $CONFIG{$module};
  }
  my $zz = eval " require $module ";     ## no critic (StringyEval)
  if ($@) {
    carp "Forks::Super::CONFIG: ",
      "Module $module could not be loaded: $@\n" if $warn;
    return 0;
  }

  if (@settings) {
    $zz = eval " $module->import(\@settings) ";  ## no critic (StringyEval)
    if ($@) {
      carp "Forks::Super::CONFIG: ",
	"Module $module was loaded but could not import with settings [",
	join (',', @settings), "]\n" if $warn;
    }
  }
  if ($IS_TEST_CONFIG) {
    print STDERR "CONFIG\{$module\} enabled\n";
  }
  return 1;
}

sub CONFIG_external_program {
  my ($external_program) = @_;
  if (defined $CONFIG{$external_program}) {
    return $CONFIG{$external_program};
  }

  if (-x $external_program) {
    if ($IS_TEST_CONFIG) {
      print STDERR "CONFIG\{$external_program\} enabled\n";
    }
    return $external_program;
  }

  my $xprogram = $external_program;
  $xprogram =~ s:^/::;
  my $which = `which $xprogram 2>/dev/null`;   # won't work on all systems
  $which =~ s/\s+$//;
  if ($which && -x $which) {
    if ($IS_TEST_CONFIG) {
      print STDERR "CONFIG\{$external_program\} enabled\n";
    }
    return $CONFIG{$external_program} = $CONFIG{$which} = $which;
  }

  # poor man's which
  my @path1 = split /:/, $ENV{PATH};
  my @path2 = split /;/, $ENV{PATH};
  foreach my $path (@path1, @path2, '.') {
    if (-x "$path/$xprogram") {
      if ($IS_TEST_CONFIG) {
	print STDERR "CONFIG\{$external_program\} enabled\n";
      }
      return $CONFIG{$external_program} = "$path/$xprogram";
    }
  }
  return 0;
}

1;
