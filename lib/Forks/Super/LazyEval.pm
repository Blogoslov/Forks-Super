#
# Forks::Super::LazyEval - bg_eval, bg_qx implementations
#

package Forks::Super::LazyEval;
use Forks::Super::Config qw(:all);
use Exporter;
use Carp; 
use strict; 
use warnings;

our @ISA = qw(Exporter);
our @EXPORT = qw(bg_eval bg_qx);

$Forks::Super::LazyEval::USE_ZCALAR = 0;   # enable experimental feature

sub _choose_protocol {
  if (CONFIG_module('YAML')) {
    return 'YAML';
  }
  if (CONFIG_module('JSON')) {
    return $JSON::VERSION >= 2.0 ? 'JSON2' : 'JSON1';
  }
  if (CONFIG_module('YAML::Tiny')) {
    return 'YAML::Tiny';
  }
  if (CONFIG_module('Data::Dumper')) {
    return 'Data::Dumper';
  }
  return;
}

sub bg_eval (&;@) {
  my $proto = _choose_protocol();
  if (!defined $proto) {
    croak "Forks::Super: bg_eval call requires either YAML or JSON\n";
  }
  my ($code, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq 'HASH') {
    @other_options = %{$other_options[0]};
  }

  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    # timeout, expiration are incompatible with bg_eval
    foreach (@other_options) {
      if ($_ eq "timeout" || $_ eq "expiration") {
	croak "Forks::Super::bg_eval: ",
	  "$_ option not allowed because ",
	  "alarm/sleep are not compatible on this system.\n";
      }
    }
  }

  my $p = $$;
  my ($result, @result);
  if (wantarray) {
    require Forks::Super::Tie::BackgroundArray;
    tie @result, 'Forks::Super::Tie::BackgroundArray',
      'eval', $code, 
      protocol => $proto,
      @other_options;
    return @result;
  } else {
    require Forks::Super::Tie::BackgroundScalar;
    $result = new Forks::Super::Tie::BackgroundScalar
      'eval', $code, 
      protocol => $proto,
      @other_options;
    if ($$ != $p) {
      # a WTF observed on Windows
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return $result;
  }
}

sub bg_qx {
  my ($command, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq 'HASH') {
    @other_options = %{$other_options[0]};
  }

  if ($Forks::Super::SysInfo::SLEEP_ALARM_COMPATIBLE <= 0) {
    # timeout, expiration are incompatible with bg_qx
    foreach (@other_options) {
      if ($_ eq "timeout" || $_ eq "expiration") {
	croak "Forks::Super::bg_qx: ",
	  "$_ option not allowed because ",
	  "alarm/sleep are not compatible on this system.\n";
      }
    }
  }

  my $p = $$;
  my (@result, $result);
  if (wantarray) {
    require Forks::Super::Tie::BackgroundArray;
    tie @result, 'Forks::Super::Tie::BackgroundArray',
      'qx', $command, @other_options;
    return @result;
  } else {
    require Forks::Super::Tie::BackgroundScalar;
    $result =  new Forks::Super::Tie::BackgroundScalar
      'qx', $command, @other_options;
    if ($$ != $p) {
      # a WTF observed on Windows
      croak "Forks::Super::bg_qx: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return $result;
  }
}

1;
