#
# Forks::Super::Debug package - manage Forks::Super module-specific
#         debugging messages
#

package Forks::Super::Debug;
use Forks::Super::Util;
use IO::Handle;
use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our @EXPORT_OK = qw(debug $DEBUG carp_once);
our %EXPORT_TAGS = (all => [ @EXPORT_OK ]);

our ($DEBUG, $DEBUG_fh);
our $VERSION = $Forks::Super::Util::VERSION;

open($DEBUG_fh, '>&STDERR')
  or $DEBUG_fh = *STDERR
  or carp_once("Forks::Super: Debugging not available in module!\n");
$DEBUG_fh->autoflush(1);
$DEBUG = $ENV{FORKS_SUPER_DEBUG} || '0';

sub init {
}

sub debug {
  my @msg = @_;
  print $DEBUG_fh $$," ",Forks::Super::Util::Ctime()," ",@msg,"\n";
  return;
}

# sometimes we only want to print a warning message once
our %_CARPED = ();
sub carp_once {
  my @msg = @_;
  my ($p,$f,$l) = caller;
  my $z = '';
  if (ref $msg[0] eq 'ARRAY') {
    $z = join ';', @{$msg[0]};
    shift;
  }
  return if $_CARPED{"$p:$f:$l:$z"}++;
  carp @msg;
}

1;
