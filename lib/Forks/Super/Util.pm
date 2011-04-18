#
# Forks::Super::Util - useful routines that could be helpful
#                      to any of the other Forks::Super::Xxx
#                      packages
#

package Forks::Super::Util;
use Exporter;
use Carp;
use strict;
use warnings;

use constant IS_WIN32 => $^O =~ /os2|Win32/i;
use constant IS_CYGWIN => $^O =~ /cygwin/i;

our @ISA = qw(Exporter);
our $VERSION = '0.50';
our @EXPORT_OK = qw(Ctime is_number isValidPid pause qualify_sub_name 
		    is_socket is_pipe IS_WIN32 IS_CYGWIN);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our (%SIG_NO, @SIG_NAME, $Time_HiRes_avail,
    $something_productive, $something_else_productive);
our ($DEFAULT_PAUSE, $_PAUSE) = (0.10, 0);

$Time_HiRes_avail = eval  { use Time::HiRes; 1 } || 0;
if (!$Time_HiRes_avail) {
  *Time::HiRes::time = \&time;
  *Time::HiRes::sleep = \&__fake_Time_HiRes_sleep;
}


sub __fake_Time_HiRes_sleep {
  my $delay = shift;
  return 0.01 if $delay <= 0;
  if ($delay > 0 && $delay <= 1) {
    return CORE::sleep 1;
  } else {
    return CORE::sleep int($delay);
  }
}

sub Ctime {
  my $t = Time::HiRes::time(); #Time();
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
  my ($pid, $is_wait) = @_;

  if (ref $pid eq 'Forks::Super::Job') {
    # DWIM - if the job is completed, isValidPid() was probably called from
    #    the output of a waitpid/wait call, so test {real_pid} and not {pid}
    #    DWIM behavior can be overridden with $is_wait argument.

    $is_wait ||= 0;
    if ($is_wait < 0) {
      $pid = $pid->{pid};
    } elsif ($is_wait > 0) {
      $pid = $pid->{real_pid};
    } elsif ($pid->is_complete) {
      $pid = $pid->{real_pid} || $pid->{pid}
    } else {
      $pid = $pid->{pid};
    }
  }
  return 0 if !defined($pid) || !is_number($pid);
  return &IS_WIN32 ? $pid > 0 || ($pid <= -2 && $pid >= -50000) : $pid > 0;
}

sub set_productive_pause_code (&) {
  $something_productive = shift;
}

sub set_other_productive_pause_code (&) {
  $something_else_productive = shift;
}

# productive "sleep" function
sub pause {
  my $start = Time::HiRes::time();
  my $delay = shift || $DEFAULT_PAUSE;
  my $unproductive = shift || 0;
  my $expire = $start + ($delay || 0.25);

  $_PAUSE++; # prevent too much productive code from nested pause calls

  if ($Time_HiRes_avail) {
    my $time_left = $expire - Time::HiRes::time();
    while ($time_left > 0) {
      if ($_PAUSE < 2 && $something_productive && !$unproductive) {
	$something_productive->();
	$time_left = $expire - Time::HiRes::time();
	last if $time_left <= 0;
      }
      my $resolution = $time_left > $DEFAULT_PAUSE
			? $DEFAULT_PAUSE
			: $time_left * 0.5 + 0.01;
      Time::HiRes::sleep($resolution || 0.25);
      $time_left = $expire - Time::HiRes::time();
    }
  } else {
    my $stall = $delay * 0.1;
    $stall = 0.1 if $stall < 0.1;
    $stall = $delay if $stall > $delay;
    $stall = $DEFAULT_PAUSE if $stall > $DEFAULT_PAUSE;

    while ($delay > 0) {
      if ($_PAUSE < 2 && $something_productive && !$unproductive) {
	$something_productive->();
	$delay = Time::HiRes::time() - $expire;
	last if $delay <= 0;
      }

      if ($stall >= 1) {
	CORE::sleep $stall;
      } else {
	# emulate sleep with 4-arg select
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
  return Time::HiRes::time() - $start;
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

sub signal_name {
  my $num = shift;
  if ($num =~ /\D/) {
    return $num;
  }
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

sub _has_POSIX_signal_framework {
  return !&IS_WIN32; # XXX - incomplete, but covers the most important case
}

sub is_socket {
  my $handle = shift;
  if (ref tied *$handle eq 'Forks::Super::Tie::IPCFileHandle') {
    return 0;
  }
  if (ref tied *$handle eq 'Forks::Super::Tie::IPCSocketHandle') {
    return 1;
  }
  if (defined $$handle->{is_socket}) {
    return $$handle->{is_socket};
  }
  return defined getsockname($handle);
}

sub is_pipe {
  my $handle = shift;
  if (defined $$handle->{is_pipe}) {
    return $$handle->{is_pipe};
  }
  if ($$handle->{is_socket} || $$handle->{is_file} || 0) {
    return 0;
  }
  if (defined $handle->{std_delegate}) {
    $handle = $handle->{std_delegate};
  }
  return eval { $handle->opened } && -p $handle;
}

1;
