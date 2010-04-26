use Forks::Super ':test';
use Forks::Super::Config ':all';
use Test::More tests => 4;
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


######################################################################

# update priority

SKIP: {
  my $pid1 = fork { sub => sub { sleep 10 } };
  sleep 1;
  my $p1 = $^O eq 'MSWin32' 
    ? Forks::Super::Job::OS::Win32::get_thread_priority($pid1) 
    : getpriority(0,$pid1);

  if ($p1 == 20) { # min priority on Unix
    skip "update priority test. Process is already at min priority", 1;
  }
  # change of plus 1 from default should be meaningful 
  # and valid on both Win32, Unix
  my $pid2 = fork { sub => sub { sleep 10 }, os_priority => $p1 + 1 };
  sleep 1;
  my $p2 = $^O eq 'MSWin32' 
    ? Forks::Super::Job::OS::Win32::get_thread_priority($pid2) 
    : getpriority(0,$pid2);
  ok($p1 != $p2, "priority has changed  $p1 / $p2");
  ok($p2 == $p1 + 1, "priority has changed by right amount");
}

######################################################################

# update cpu affinity

SKIP: {
  local $!;
  my $lenient = 0;

  if (!CONFIG("Sys::CpuAffinity")) {
    skip "cpu affinity test: requires Sys::CpuAffinity", 1;
  }

  my $np = Sys::CpuAffinity::getNumCpus();
  if ($np == 1) {
    skip "cpu affinity test: single-core system detected", 1;
  }
  if ($np <= 0) {
    skip "cpu affinity test: could not detect number of processors!", 1;
  }

  my $pid3 = fork { sub => sub { sleep 10 }, cpu_affinity => 0x02 };
  if (!isValidPid($pid3)) {
    ok(0, "fork failed with cpu_affinity option");
  } else {
    sleep 5;
    my $affinity = Sys::CpuAffinity::getAffinity($pid3);
    ok($affinity == 0x02, "set cpu affinity $affinity==2");
  }
}

# XXX check:  cpu_affinity => 0, cpu_affinity => -1, cpu_affinity => 1<<32
#             all give warnings, have no effect.

######################################################################

# Win32-specific test. A spawned job should have the same CPU affinity
# from the psuedo-process (thread) that spawned it

SKIP: {
  if ($^O ne 'MSWin32') {
    skip "cpu affinity test of Win32 Process object on $^O", 1;
  }

  unlink "t/out/test-os";
  my $pid = fork {
    cmd => [ $^X, "t/external-command.pl", 
	     "-o=t/out/test-os", "--winpid", "-s=10" ],
      cpu_affinity => 1
  };
  sleep 2;
  open(T, "<", "t/out/test-os");
  my $winpid = <T>;
  close T;

  my $phandle = Forks::Super::Job::OS::Win32::get_process_handle($winpid);
  if ($phandle) {
    my ($proc_affinity, $sys_affinity) = (0,0);
    my $result 
      = Forks::Super::Job::OS::Win32::win32api("GetProcessAffinityMask",
					     $phandle, $proc_affinity,
					     $sys_affinity);
    $proc_affinity = ord($proc_affinity);
    ok($result != 0 && $proc_affinity == 1, 
       "MSWin32 set affinity on external Win32::Process $proc_affinity==1");
  } else {
    ok(0, "could not obtain handle to external process on pid $winpid");
  }
}

waitall;

######################################################################

sub win32_getpriority {
  my ($thread_id) = @_;
  sleep 1;
  $thread_id = abs($thread_id);
  if (!CONFIG("Win32::API")) {
    return;
  }

  my $api = \&Forks::Super::Job::OS::Win32::win32api;
  my $handle = Forks::Super::Job::OS::Win32::get_thread_handle($thread_id);
  if ($handle) {
    local $!;
    undef $!;
    my $p = $api->('GetThreadPriority',$handle);
    if ($p > 2**31) {
      warn "Error getting Win32 thread priority: $! $^E";
    }
    return $p;
  }
  return;
}

