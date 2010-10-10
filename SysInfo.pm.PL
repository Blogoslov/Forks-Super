# SysInfo.pm.PL
# Create the lib/Forks/Super/SysInfo.pm file
# with information about the current system
# and some of its capabilities.
# See also: system-limits.PL

use lib qw(lib);
use Forks::Super::Util;
use strict;
use warnings;

my $limits_file = "t/out/limits.$^O.$]";

if (! -r $limits_file) {
  print STDERR "$0: creating system-limits file.\n";
  system($^X, "system-limits.PL", $limits_file);
}

my %info = load_limits_file($limits_file);

open F, '>', $ARGV[0] || 'lib/Forks/Super/SysInfo.pm';
print F <<"____;";

package Forks::Super::SysInfo;
use strict;
use warnings;

# This package contains some estimates about your
# system's capabilities that were discovered during
# the build/installation process of  Forks::Super .

# This information may not be accurate and is not
# intended for any other purpose.

____;

printF('SYSTEM', "'$info{system}'", "'unknown'");
printF('PERL_VERSION', "'$info{version}'", "'unknown'");
printF('MAX_FORK', $info{maxfork}, '12.345');
printF('MAX_OPEN_FH', $info{maxfilehandle}, '123.456');
printF('SOCKET_CAPACITY', $info{socket_capacity}, '128.0');
printF('PIPE_CAPACITY', $info{pipe_capacity}, '128.0');
printF('SLEEP_ALARM_COMPATIBLE', $info{sleep_alarm_compat}, '""');
if (defined $info{ncpu}) {
  printF('NUM_PROCESSORS', $info{ncpu}, '1');
}

print F "\n\n1;\n";
close F;


sub printF {
  my ($varName, $value, $defaultValue) = @_;
  $value = $defaultValue if $value eq "''";
  $value ||= $defaultValue;
  $value = "0" if $value eq "000";

  print F "\r\n";
  print F 'our $', $varName, " = $value;", "\r\n";
}

sub load_limits_file {
  my ($f) = @_;
  my %info;
  open L, '<', $f;
  while (<L>) {
    s/\s+$//;
    my ($key, $value) = split /:/, $_, 2;
    $info{$key} = $value;
  }
  close L;
  return %info;
}

