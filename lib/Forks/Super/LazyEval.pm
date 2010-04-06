#
# Forks::Super::LazyEval - bg_eval, bg_qx implementations
#

package Forks::Super::LazyEval;

use base 'Exporter';
use Forks::Super::Config qw(:all);
use Carp; 
use strict; 
use warnings;

our @EXPORT = qw(bg_eval bg_qx);

sub bg_eval (&;@) {
  my $useYAML = CONFIG("YAML");
  my $useJSON = CONFIG("JSON");
  if (!($useYAML || $useJSON)) {
    croak "Forks::Super: bg_eval call requires either YAML or JSON\n";
  }
  my ($code, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq "HASH") {
    @other_options = %{$other_options[0]};
  }
  my $p = $$;
  my ($result, @result);
  if (wantarray) {
    require Forks::Super::Tie::BackgroundArray;
    tie @result, 'Forks::Super::Tie::BackgroundArray',
      'eval', $code, 
      use_YAML => $useYAML, use_JSON => $useJSON, 
      @other_options;
    return @result;
  } else {
    require Forks::Super::Tie::BackgroundScalar;
    tie $result, 'Forks::Super::Tie::BackgroundScalar',
      'eval', $code, 
      use_YAML => $useYAML, use_JSON => $useJSON,
      @other_options;
    if ($$ != $p) {
      # a WTF observed on MSWin32
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return \$result;
  }
}

sub bg_qx {
  my ($command, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq "HASH") {
    @other_options = %{$other_options[0]};
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
    tie $result, 'Forks::Super::Tie::BackgroundScalar',
      'qx', $command, @other_options;
    if ($$ != $p) {
      # a WTF observed on MSWin32
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return \$result;
  }
}

1;
