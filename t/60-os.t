use Forks::Super ':test_config';
use Test::More tests => 3;
use strict;
use warnings;

#
# 60-os.t
#
# test features that interact with the operating system,
# like setting the priority of a background process
# or setting the CPU affinity of a background process
#

SKIP: {
  skip "getpriority() not avail on Win32", 2 if $^O eq "MSWin32";
  my $pid1 = fork { sub => sub { sleep 10 } };
  sleep 1;
  my $p1 = getpriority(0,$pid1);
  my $pid2 = fork { sub => sub { sleep 10 }, os_priority => $p1 + 3 };
  sleep 1;
  my $p2 = getpriority(0,$pid2);
  ok($p1 != $p2);
  ok($p2 == $p1 + 3);
}

SKIP: {
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
    ok($cc == 0x01, "Updated process affinity on Linux $c");
  } elsif ($^O eq "MSWin32" && Forks::Super::CONFIG("Win32::API")) {
    sleep 2;
    my $x = Forks::Super::Job::_get_win32_thread_api();
    my $handle = $x->{"OpenThread"}->Call(0x0060, 0, abs($pid3));
    my $y = $x->{"SetThreadAffinityMask"}->Call($handle, 3);
    $x->{"SetThreadAffinityMask"}->Call($handle,$y);
    ok($y == 0x01, "Updated process affinity on Win32 $y == 0x01");
  } else {
    skip "skipping cpu affinity test: unsupported or unimplemented OS", 1;
  }
}

waitall;
