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

our @EXPORT_OK = qw(debug $DEBUG);
our %EXPORT_TAGS = (all => [ @EXPORT_OK ]);

our ($DEBUG, $DEBUG_fh);
our $VERSION = $Forks::Super::Util::VERSION;

open($DEBUG_fh, '>&STDERR')
  or $DEBUG_fh = *STDERR
  or carp "Forks::Super: Debugging not available in module!\n";
$DEBUG_fh->autoflush(1);
$DEBUG = $ENV{FORKS_SUPER_DEBUG} || "0";

sub init {
}

sub debug {
  my @msg = @_;
  print $DEBUG_fh Forks::Super::Util::Ctime()," ",@msg,"\n";
  return;
}

1;
