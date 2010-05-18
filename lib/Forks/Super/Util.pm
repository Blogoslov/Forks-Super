#
# Forks::Super::Util - useful routines that could be helpful
#                      to any of the other Forks::Super::Xxx
#                      packages
#

package Forks::Super::Util;
use Exporter;
use base 'Exporter';
use Carp;
use strict;
use warnings;

our $VERSION = '0.32';
our @EXPORT_OK = qw(Time Ctime is_number isValidPid pause qualify_sub_name);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our $DEFAULT_PAUSE = 0.10;
our ($Time_HiRes_avail, $something_productive, $something_else_productive);
our $_PAUSE = 0;

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

  # from Scalar::Util::PP::looks_like_number:
  return $a =~ /^[+-]?[0-9]+$/ ||
    $a =~ /^([+-]?)(?=[0-9]|\.[0-9])[0-9]*(\.[0-9]*)?([Ee]([+-]?[0-9]+))?$/;
}

# portable function call to check the return value of fork()
# and see if the call succeeded. For a fork() call that
# results in a "deferred" job, this function will
# return zero.
sub isValidPid {
  my ($pid) = @_;
  return 0 if !defined $pid || !is_number($pid);
  return $^O eq 'MSWin32' ? $pid > 0 || ($pid <= -2 && $pid >= -50000) : $pid > 0;
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
  my $unproductive = shift || 0;
  my $expire = $start + ($delay || 0.25);

  $_PAUSE++; # prevent too much productive code from nested pause calls

  if ($Time_HiRes_avail) {
    my $time_left = $expire - Forks::Super::Util::Time();
    while ($time_left > 0) {
      if ($_PAUSE < 2 && $something_productive && !$unproductive) {
	$something_productive->();
	$time_left = $expire - Forks::Super::Util::Time();
	last if $time_left <= 0;
      }
      my $resolution = $time_left > $DEFAULT_PAUSE ? $DEFAULT_PAUSE : $time_left * 0.5 + 0.01;
      Time::HiRes::sleep($resolution || 0.25);
      $time_left = $expire - Forks::Super::Util::Time();
    }
  } else {
    my $stall = $delay * 0.1;
    $stall = 0.1 if $stall < 0.1;
    $stall = $delay if $stall > $delay;
    $stall = $DEFAULT_PAUSE if $stall > $DEFAULT_PAUSE;

    while ($delay > 0) {
      if ($_PAUSE < 2 && $something_productive && !$unproductive) {
	$something_productive->();
	$delay = Forks::Super::Util::Time() - $expire;
	last if $delay <= 0;
      }

      if ($stall >= 1) {
	sleep $stall;
      } else {
	select undef, undef, undef, $stall < $delay ? $stall : $delay;
      }
      $delay -= $stall;
    }
  }

  if ($_PAUSE > 1 || $unproductive) {
  } elsif ($something_else_productive) {
    $something_else_productive->();
  } elsif ($something_productive) {
    $something_productive->();
  }
  $_PAUSE = 0;
  return Time() - $start;
}

#
# prepend package qualifier from current context to a scalar subroutine name.
# Useful when passing an unqualified name of a subroutine declared in the
# calling package to a Forks::Super or Forks::Super::Xxx method
# that takes a code ref.
#
sub qualify_sub_name {
  my $name = shift;
  my $invalid_package = shift || "Forks::Super";
  if (ref $name eq 'CODE' || $name =~ /::/ || $name =~ /\'/) {
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

our (%SIG_NO, @SIG_NAME);

sub signal_name {
  my $num = shift;
  _load_signal_data();
  return $SIG_NAME[$num];
}

sub signal_number {
  my $name = shift;
  _load_signal_data();
  return $SIG_NO{$name};
}

# signal names that are normally instructions to terminate a program
# this list may need some work
my %_kill_sigs = (HUP => 1, INT => 1, QUIT => 1,
		  ILL => 1, ABRT => 1, KILL => 1,
		  SEGV => 1, TERM => 1, BREAK => 1);
sub is_kill_signal {
  my $sig = shift;
  $sig = $SIG_NAME[$sig] if $sig !~ /\D/;
  return $_kill_sigs{$sig} || 0;
}

sub _load_signal_data {
  return if @SIG_NAME > 0;
  use Config;
  @SIG_NAME = split / /, $Config{sig_name};
  my $i = 0;
  %SIG_NO = map { $_ => $i++ } @SIG_NAME;
}

1;
