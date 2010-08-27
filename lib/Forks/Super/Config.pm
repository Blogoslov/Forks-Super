#
# Forks::Super::Config package - determines what features and
#         modules are available on the current system
#


package Forks::Super::Config;
use Forks::Super::Debug qw(debug);
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT_OK = qw(CONFIG);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
our (%CONFIG, $IS_TEST, $IS_TEST_CONFIG, %signo);
our $VERSION = $Forks::Super::Debug::VERSION;

sub init {
  %CONFIG = (filehandles => 1);
  $IS_TEST = 0;
  $IS_TEST_CONFIG = 0;

  $CONFIG{'Win32::API'} = 0 if $ENV{NO_WIN32_API};

  use Config;
  my $i = 0;
  if (defined $Config::Config{'sig_name'}) {
    %signo = map { $_ => $i++ } split / /, $Config::Config{'sig_name'};
  }
}

sub init_child {
  unconfig('filehandles');
}

sub unconfig {
  my $module = shift;
  $CONFIG{$module} = 0;
}

sub config {
  my $module = shift;
  if ($module eq 'filehandles') { Carp::cluck "Setting CONFIG(filehandles)\n" }
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

  # check for OS-dependent Perl functionality
  if ($module eq 'getpgrp' or $module eq 'alarm'
      or $module eq 'SIGUSR1' or $module eq 'getpriority'
      or $module eq 'select4' or $module eq 'pipe') {

    return $CONFIG{$module} = _CONFIG_Perl_component($module);
  } elsif (substr($module,0,1) eq '/') {
    return $CONFIG{$module} = _CONFIG_external_program($module);
  } elsif ($module eq 'filehandles') {
#   print STDERR "XXXXXX CONFIG(fh) enabled\n";
    return $CONFIG{$module} = 1; # available by default
  } else {
    return $CONFIG{$module} =
      _CONFIG_module($module,$warn,@settings);
  }
}

sub _CONFIG_module {
  my ($module,$warn, @settings) = @_;
  my $zz = eval " require $module ";
  if ($@) {
    carp "Forks::Super::CONFIG: ",
      "Module $module could not be loaded: $@\n" if $warn;
    return 0;
  }

  if (@settings) {
    $zz = eval " $module->import(\@settings) ";
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

sub _CONFIG_Perl_component {
  my ($component) = @_;
  local $@;
  if ($component eq 'getpgrp') {
    undef $@;
    my $z = eval { getpgrp(0) };
    $CONFIG{'getpgrp'} = $@ ? 0 : 1;
  } elsif ($component eq 'getpriority') {
    undef $@;
    my $z = eval { getpriority(0,0) };
    $CONFIG{'getpriority'} = $@ ? 0 : 1;
  } elsif ($component eq 'alarm') {
    undef $@;
    my $z = eval { alarm 0 };
    $CONFIG{'alarm'} = $@ ? 0 : 1;
  } elsif ($component eq 'SIGUSR1') {

    # %SIG is a special hash -- defined $SIG{USR1} might be false
    # but USR1 might still appear in keys %SIG.

    my $SIG = join ' ', ' ', keys %SIG, ' ';
    my $target_sig = defined $Forks::Super::QUEUE_INTERRUPT
      ? $Forks::Super::QUEUE_INTERRUPT : '';
    $CONFIG{'SIGUSR1'} =
      $SIG =~ / $target_sig / ? 1 : 0;
  } elsif ($component eq 'select4') { # 4-arg version of select
    undef $@;
    my $z = eval { select undef,undef,undef,0.5 };
    $CONFIG{'select4'} = $@ ? 0 : 1;
  } elsif ($component eq 'pipe') {
    undef $@;
    eval {
      my ($read,$write);
      pipe $read, $write;
      close $read;
      close $write;
    };
    $CONFIG{'pipe'} = $@ ? 0 : 1;
  }

  # getppid  is another OS-dependent Perl system call

  if ($IS_TEST_CONFIG) {
    if ($CONFIG{$component}) {
      print STDERR "CONFIG\{$component\} enabled\n";
    } else {
      print STDERR "CONFIG\{$component\} failed\n";
    }
  }
  return $CONFIG{$component};
}

sub _CONFIG_external_program {
  my ($external_program) = @_;

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
