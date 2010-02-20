#
# Forks::Super::Util - useful routines that could be helpful
#                      to any of the other Forks::Super::XXX
#                      packages
# 

package Forks::Super::Util;

use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our @EXPORT_OK = qw(Time Ctime is_number isValidPid pause qualify_sub_name);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our $DEFAULT_PAUSE = 0.25;
our ($Time_HiRes_avail, $something_productive, $something_else_productive);

my $x = eval "use Time::HiRes";
if ($@) {
  $Time_HiRes_avail = 0;
} else {
  $Time_HiRes_avail = 1;
}

sub Time {
  return $Time_HiRes_avail 
    ? scalar Time::HiRes::gettimeofday() : CORE::time();
}

sub Ctime {
  my $t = Time();
  return sprintf "%02d:%02d:%02d.%03d: ", 
    ($t/3600)%24, ($t/60)%60, $t%60, ($t*1000)%1000;
}

sub is_number {
  my $a = shift;
  $a =~ s/^\s+//;
  $a =~ s/\s+$//;
  $a =~ s/e[+-]?\d+$//i;
  $a =~ s/^[\+\-]//;
  $a =~ /^\d+.?\d*$/ || $a =~ /^\.\d+/;
}

# a portable way to check the return value of fork()
# and see if the call succeeded. For a fork() call that
# results in a "deferred" job, this function will
# return zero.
sub isValidPid {
  my ($pid) = @_;
  return $^O eq "MSWin32" ? $pid != 0 && $pid != -1 && $pid >= -50000 : $pid > 0;
}

sub set_productive_pause_code (&) {
  $something_productive = shift;
}

sub set_other_productive_pause_code (&) {
  $something_else_productive = shift;
}

# productive "sleep" function
sub pause {
  my $start = Forks::Super::Util::Time();
  my $delay = shift || $DEFAULT_PAUSE;
  my $expire = $start + ($delay || 0.25);

  if ($Time_HiRes_avail) {
    while (Forks::Super::Util::Time() < $expire) {
      if ($something_productive) {
	$something_productive->();
      }
      Time::HiRes::sleep(0.1 * ($delay || 1));
    }
  } else {
    my $stall = $delay * 0.1;
    $stall = 0.1 if $stall < 0.1;
    $stall = $delay if $stall > $delay;
    $stall = 0.10 if $stall > 0.10;

    while ($delay > 0) {
      if ($something_productive) {
	$something_productive->();
      }

      if ($stall >= 1) {
	sleep $stall;
      } else {
	select undef, undef, undef, $stall < $delay ? $stall : $delay;
      }
      $delay -= $stall;
    }
  }

  if ($something_else_productive) {
    $something_else_productive->();
  } elsif ($something_productive) {
    $something_productive->();
  }
  return Time() - $start;
}

#
# prepend package qualifier from current context to a scalar subroutine name.
# Useful when passing an unqualified name of a subroutine declared in the 
# calling package to a Forks::Super or Forks::Super::XXX method 
# that takes a code ref.
#
sub qualify_sub_name {
  my $name = shift;
  my $invalid_package = shift || "Forks::Super";
  if (ref $name eq "CODE" || $name =~ /::/ || $name =~ /\'/) {
    return $name;
  }

  my $i = 2;
  my $calling_package = caller($i);
  while ($calling_package =~ /$invalid_package/) {
    $i++;
    $calling_package = caller($i);
  }
  return join "::", $calling_package, $name;
}

1;


