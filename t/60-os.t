use Forks::Super ':test';
use Test::More tests => 3;
use strict;
use warnings;

# XXX - consider breaking this up into separate scripts for each system:
#         60-os-linux.t
#         60-os-MSWin32.t
#         ...
#         60-os-other.t

#
# 60-os.t
#
# test features that interact with the operating system,
# like setting the priority of a background process
# or setting the CPU affinity of a background process
#

sub win32_getpriority {
  my ($thread_id) = @_;
  sleep 1;
  $thread_id = abs($thread_id);
  my $api = Forks::Super::Job::OS::_get_win32_thread_api();
  my $handle = $api->{OpenThread}->Call(0x0060, 0, $thread_id);
  if ($handle) {
    local $!;
    undef $!;
    my $p = $api->{GetThreadPriority}->Call($handle);
    if ($p > 2**31) {
      warn "Error getting Win32 thread priority: $! $^E";
    }
    return $p;
  }
  return;
}

SKIP: {
  if ($^O eq "MSWin32") {
    if (!Forks::Super::CONFIG("Win32::API") ||
	defined Forks::Super::Job::OS::_get_win32_thread_api->{"_error"}) {
      skip "getpriority() not avail on Win32", 2;
    }
  }

  my $pid1 = fork { sub => sub { sleep 10 } };
  sleep 1;
  my $p1 = $^O eq "MSWin32" ? win32_getpriority($pid1) : getpriority(0,$pid1);
  # change of plus 2 from default should be meaningful and valid on both Win32, Unix
  my $pid2 = fork { sub => sub { sleep 10 }, os_priority => $p1 + 2 };
  sleep 1;
  my $p2 = $^O eq "MSWin32" ? win32_getpriority($pid2) : getpriority(0,$pid2);
  ok($p1 != $p2, "priority has changed");
  ok($p2 == $p1 + 2, "priority has changed by right amount");
}

SKIP: {
  local $!;
  if (Forks::Super::CONFIG("Sys::CPU")) {
    if (Sys::CPU::cpu_count() < 2) {
      skip "skipping cpu affinity test: single-core system detected", 1;
    }
  }
  my $pid3 = fork { sub => sub { sleep 5 }, cpu_affinity => 0x01 };
  if (!isValidPid($pid3)) {
    ok(0, "fork failed with cpu_affinity option");
  } elsif ($^O eq "cygwin") {
    if (Forks::Super::CONFIG("Win32::Process")) {
      my $winpid = Cygwin::pid_to_winpid($pid3);
      my $handle;
      if (Win32::Process::Open($handle, $winpid, 0)) {
	sleep 2;
	my ($pmask, $smask);
	$handle->GetProcessAffinityMask($pmask,$smask);
	ok($pmask == 0x01, "Updated process affinity on Cygwin $pmask == 1");
      } else{
	skip "skipping cpu affinity test: "
	  ."could not obtain Win32 process handle", 1;
      }
    } else {
      skip "skipping cpu affinity test: missing required module", 1;
    }
  } elsif ($^O =~ /linux/i && Forks::Super::CONFIG("/bin/taskset")) {
    my $taskset = Forks::Super::CONFIG("/bin/taskset");
    my $c = `"$taskset" -p $pid3`;
    my ($cc) = $c =~ /: (\S+)/;
    $cc = hex($cc);

    if ($cc == 1) {
      ok($cc == 1, "Updated process affinity on Linux $c");
    } else {
      skip "cpu affinity test failed on $^O. This is a minor test failure that shouldn't break the installation process.", 1;
    }
  } elsif ($^O eq "MSWin32" && Forks::Super::CONFIG("Win32::API")) {
    sleep 2;
    my $x = Forks::Super::Job::OS::_get_win32_thread_api();
    my $handle = $x->{"OpenThread"}->Call(0x0060, 0, abs($pid3));
    undef $!;
    my $y = $x->{"SetThreadAffinityMask"}->Call($handle, 3);
    if ($y == 0) {
      warn "Failed to get thread cpu affinity $^E. Retrying.\n";
      $y = $x->{"SetThreadAffinityMask"}->Call($handle, 1);
      if ($y == 0) {
	skip "skip cpu affinity test: can't determine current thread cpu affinity", 1;
      }
    }
    $x->{"SetThreadAffinityMask"}->Call($handle,$y);
    ok($y == 0x01, "Updated process affinity on Win32 $y == 0x01");
  } else {
    skip "skipping cpu affinity test: unsupported or unimplemented OS", 1;
  }
}

waitall;
