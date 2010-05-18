use lib qw(lib);
use Forks::Super::Util;
use strict;
use warnings;

if (-r 'system-limits') {
  my %info = load_limits_file('system-limits');
  if ($info{system} ne $^O || $info{version} ne $]) {
    print STDERR "system-limits file is outdated.\n";
    print STDERR "system-limits => system-limits.$info{system}.$info{version}\n";
    rename 'system-limits', "system-limits.$info{system}.$info{version}";
  }
}


if (! -r 'system-limits') {
  print STDERR "$0: creating system-limits file.\n";
  system($^X, "system-limits.PL", "system-limits");
}

my %info = load_limits_file('system-limits');

open F, '>', $ARGV[0] || 'lib/Forks/Super/SysInfo.pm';
print F <<"____;";

package Forks::Super::SysInfo;

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

print F "

1;
";

close F;


sub printF {
  my ($varName, $value, $defaultValue) = @_;
  $value = $defaultValue if $value eq "''";
  $value ||= $defaultValue;

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

