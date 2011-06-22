#
# Forks::Super::Debug package - manage Forks::Super module-specific
#         debugging messages
#

package Forks::Super::Debug;
use Forks::Super::Util;
use IO::Handle;
use Exporter;
use Carp;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(debug $DEBUG carp_once);
our %EXPORT_TAGS = (all => [ @EXPORT_OK ]);
our $VERSION = '0.52';

our ($DEBUG, $DEBUG_FH, %_CARPED, 
     $OLD_SIG__WARN__, $OLD_SIG__DIE__, $OLD_CARP_VERBOSE);

## no critic (BriefOpen,TwoArgOpen)
(uc($ENV{FORKS_SUPER_DEBUG} || "") eq 'TTY'
 && open($DEBUG_FH, '>', $^O eq 'MSWin32' ? 'CON' : '/dev/tty'))
  or open($DEBUG_FH, '>&2')
  or $DEBUG_FH = *STDERR
  or carp_once("Forks::Super: Debugging not available in module!\n");
## use critic
$DEBUG_FH->autoflush(1);
$DEBUG = !!$ENV{FORKS_SUPER_DEBUG} || '0';

sub init {
}

sub debug {
  my @msg = @_;
  print {$DEBUG_FH} $$," ",Forks::Super::Util::Ctime()," ",@msg,"\n";
  return;
}

# sometimes we only want to print a warning message once
sub carp_once {
  my @msg = @_;
  my ($p,$f,$l) = caller;
  my $z = '';
  if (ref $msg[0] eq 'ARRAY') {
    $z = join ';', @{$msg[0]};
    shift @msg;
  }
  return if $_CARPED{"$p:$f:$l:$z"}++;
  return carp @msg;
}

# load or emulate Carp::Always for the remainder of the program
sub use_Carp_Always {
  $OLD_CARP_VERBOSE = $Carp::Verbose if !defined($OLD_CARP_VERBOSE);
  $Carp::Verbose = 'verbose';
  if (!defined($OLD_SIG__WARN__)) {
    $OLD_SIG__WARN__ = $SIG{__WARN__} || 'DEFAULT';
    $OLD_SIG__DIE__ = $SIG{__DIE__} || 'DEFAULT';
  }
  ## no critic (RequireCarping)
  $SIG{__WARN__} = sub { warn &Carp::longmess };
  $SIG{__DIE__} = sub { warn &Carp::longmess };
  return 1;
}

# stop emulation of Carp::Always
sub no_Carp_Always {
  $Carp::Verbose = $OLD_CARP_VERBOSE || 0;
  $SIG{__WARN__} = $OLD_SIG__WARN__ || 'DEFAULT';
  $SIG{__DIE__} = $OLD_SIG__DIE__ || 'DEFAULT';
  return;
}

1;
