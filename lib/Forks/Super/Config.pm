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
use Carp;

use Exporter;
our @ISA = qw(Exporter);
#use base 'Exporter';

use strict;
use warnings;

our @EXPORT_OK = qw(CONFIG CONFIG_module);
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
      or $module eq 'select4' or $module eq 'pipe'
      or $module eq 'setitimer' or $module eq 'socketpair') {

    return $CONFIG{$module} = CONFIG_Perl_component($module);
  } elsif (substr($module,0,1) eq '/') {
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

sub CONFIG_Perl_component {
  my ($component) = @_;
  if (defined $CONFIG{$component}) {
    return $CONFIG{$component};
  }

  no warnings;
  local $SIG{__DIE__} = sub{}; # I mean it! no warnings.

  if ($component eq 'getpgrp') {
    $CONFIG{'getpgrp'} = eval { getpgrp(0); 1 } || 0;
  } elsif ($component eq 'getpriority') {
    $CONFIG{'getpriority'} = eval { getpriority(0,0); 1 } || 0;
  } elsif ($component eq 'alarm') {
    $CONFIG{'alarm'} = eval { alarm 0; 1 } || 0;
  } elsif ($component eq 'SIGUSR1') {

    # %SIG is a special hash -- defined $SIG{USR1} might be false
    # but USR1 might still appear in keys %SIG.
    # XXX - but couldn't I just say  exists $SIG{USR1} ?

    my $SIG = join ' ', ' ', keys %SIG, ' ';
    my $target_sig = defined $Forks::Super::QUEUE_INTERRUPT
      ? $Forks::Super::QUEUE_INTERRUPT : '';
    $CONFIG{'SIGUSR1'} = $SIG =~ / $target_sig / ? 1 : 0;
  } elsif ($component eq 'select4') { # 4-arg version of select
    $CONFIG{'select4'} = eval { select undef,undef,undef,0.05 ; 1 } || 0;
  } elsif ($component eq 'pipe') {
    $CONFIG{'pipe'} = eval {
      my ($read,$write);
      pipe $read, $write;
      close $read;
      close $write;
      1;
    } || 0;
  } elsif ($component eq 'socketpair') {
    $CONFIG{'socketpair'} = eval {
      use Socket;
      my ($read,$write);
      socketpair $read, $write, AF_UNIX, SOCK_STREAM, PF_UNSPEC;
      close $read;
      close $write;
      1;
    } || 0;
  } elsif ($component eq 'setitimer') {
    $CONFIG{'setitimer'} = eval {
      use Time::HiRes;
      Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 0);
      1
    } || 0;
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
