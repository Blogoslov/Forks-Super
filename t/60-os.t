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
  my $p1 = $^O eq "MSWin32" 
    ? Forks::Super::Job::OS::Win32::get_thread_priority($pid1) 
    : getpriority(0,$pid1);
  # change of plus 1 from default should be meaningful 
  # and valid on both Win32, Unix
  my $pid2 = fork { sub => sub { sleep 10 }, os_priority => $p1 + 1 };
  sleep 1;
  my $p2 = $^O eq "MSWin32" 
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

  if (CONFIG("Sys::CPU")) {
    if (Sys::CPU::cpu_count() < 2) {
      skip "cpu affinity test: single-core system detected", 1;
    }
  }
  if ($^O eq "MSWin32" || $^O eq "cygwin") {
    if (!CONFIG("Win32::API") && !CONFIG("Win32::Process")) {
      skip "cpu affinity test: this feature requires "
	. "Win32::xxx modules which are not installed", 1;
    } elsif ($^O =~ /cygwin/i && !CONFIG("Win32::Process")) {
      skip "cpu affinity test: *testing* this feature "
	. "requires Win32::Process module which is not installed", 1;
    } elsif ($^O eq "MSWin32" && !CONFIG("Win32::API")) {
      skip "cpu affinity test: *testing* this feature "
	. "requires Win32::API module which is not installed", 1;
    }
  } elsif ($^O =~ /linux/i) {
    if (!CONFIG("/taskset") && !CONFIG("Inline::C")) {
      skip "cpu affinity test: this feature requires "
	."modules or external programs which are not installed", 1;
    } elsif (!CONFIG("/taskset")) {
      skip "cpu affinity test: *testing* this feature requires "
	. "the taskset(2) program, which is not available", 1;
    }
  } else {
    warn "Setting cpu affinity on $^O may be unsupported. ",
      "Applying leniency to this test.\n";
    $lenient = 1;
  }


  my $pid3 = fork { sub => sub { sleep 5 }, cpu_affinity => 0x02 };
  if (!isValidPid($pid3)) {
    ok(0, "fork failed with cpu_affinity option");
  } elsif ($^O eq "cygwin") {

    if (CONFIG("Win32::Process")) {
      my $winpid = Cygwin::pid_to_winpid($pid3);
      my $handle;
      if (Win32::Process::Open($handle, $winpid, 0)) {
	sleep 2;
	my ($pmask, $smask);
	$handle->GetProcessAffinityMask($pmask,$smask);
	ok($pmask == 0x02, "Updated process affinity on Cygwin $pmask == 2");
      } else{
	skip "cpu affinity test: "
	  ."could not obtain Win32 process handle", 1;
      }
    } else {
      skip "cpu affinity test: missing required module", 1;
    }
  } elsif ($^O =~ /linux/i && CONFIG("/taskset")) {
    my $taskset = CONFIG("/taskset");
    my $c = `"$taskset" -p $pid3`;
    my ($cc) = $c =~ /: (\S+)/;
    $cc = hex($cc);

    ok($cc == 2, "Updated process affinity on Linux $c");
  } elsif ($^O eq "MSWin32" && CONFIG("Win32::API")) {
    sleep 2;
    my $x = \&Forks::Super::Job::OS::Win32::win32api;
    my $handle = $x->("OpenThread",0x0060, 0, abs($pid3));
    undef $!;
    my $y = $x->("SetThreadAffinityMask",$handle, 3);
    if ($y == 0) {
      warn "Failed to get thread cpu affinity $^E. Retrying.\n";
      $y = $x->("SetThreadAffinityMask",$handle, 2);
      if ($y == 0) {
	skip "cpu affinity test: can't determine current thread affinity", 1;
      }
    }
    $x->("SetThreadAffinityMask",$handle,$y);
    ok($y == 0x02, "Updated process affinity on Win32 $y == 0x02");
  } else {
    skip "cpu affinity test: unsupported or unimplemented OS", 1;
  }
}

# XXX check:  cpu_affinity => 0, cpu_affinity => -1, cpu_affinity => 1<<32
#             all give warnings, have no effect.

######################################################################

# Win32-specific test. A spawned job should have the same CPU affinity
# from the psuedo-process (thread) that spawned it

SKIP: {
  if ($^O ne "MSWin32") {
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

