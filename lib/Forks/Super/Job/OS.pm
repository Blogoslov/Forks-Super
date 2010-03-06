#
# Forks::Super::Job::OS
# implementation of
#     fork { name => ... , os_priority => ... , 
#            cpu_affinity => 0x... }
#

package Forks::Super::Job::OS;
use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Carp;
use strict;
use warnings;

our $VERSION = $Forks::Super::Debug::VERSION;

#
# If desired and if the platform supports it, set
# job-specific operating system settings like
# process priority and CPU affinity.
# Should only be run from a child process
# immediately after the fork.
#
sub config_os_child {
  my $job = shift;

  if (defined $job->{name}) {
    $0 = $job->{name}; # might affect ps(1) output
  } else {
    $job->{name} = $$;
  }

  $ENV{_FORK_PPID} = $$ if $^O eq "MSWin32";
  if (defined $job->{os_priority}) {
    my $p = $job->{os_priority} + 0;
    my $q = -999;

    if ($^O eq "MSWin32" && Forks::Super::Config::CONFIG("Win32::API")) {
      my $win32_thread_api = _get_win32_thread_api();
      if (!defined $win32_thread_api->{"_error"}) {
	my $thread_id = $win32_thread_api->{"GetCurrentThreadId"}->Call();
	my ($handle, $old_affinity);
	if ($thread_id) {
	  $handle = $win32_thread_api->{"OpenThread"}
	    ->Call(0x0060,0,$thread_id)
	    || $win32_thread_api->{"OpenThread"}
	      ->Call(0x0400,0,$thread_id);
	}
	if ($handle) {
	  my $result = $win32_thread_api->{"SetThreadPriority"}
	    ->Call($handle,$p);
	  if ($result) {
	    if ($job->{debug}) {
	      debug("updated thread priority to $p for job $job->{pid}");
	    }
	  } else {
	    carp "Forks::Super::Job::config_os_child(): ",
	      "setpriority() call failed $p ==> $q\n";
	  }
	}
      }
    } else {
      my $z = eval "setpriority(0,0,$p); \$q = getpriority(0,0)";
      if ($@) {
	carp "Forks::Super::Job::config_os_child(): ",
	  "setpriority() call failed $p ==> $q\n";
      }
    }
  }

  if (defined $job->{cpu_affinity}) {
    my $n = $job->{cpu_affinity};
    if ($n == 0) {
      carp "Forks::Super::Job::config_os_child(): ",
	"desired cpu affinity set to zero. Is that what you really want?\n";
    }

    if ($^O =~ /cygwin/i && Forks::Super::Config::CONFIG("Win32::Process")) {
      my $winpid = Win32::Process::GetCurrentProcessID();
      my $processHandle;

      local $SIG{SEGV} = sub {
	warn "********************************************************\n",
	     "* Forks::Super: set CPU affinity failed:               *\n",
	     "* Win32::Process::SetAffinityMask() caused a SIGSEGV.  *\n",
	     "* Recommend upgrading to at least Win32::Process v0.14 *\n",
	     "********************************************************\n";	  
      };
      if (! defined $winpid) {
	carp "Forks::Super::Job::config_os_child(): ",
	  "Win32::Process::GetCurrentProcessID() returned <undef>\n";
      } elsif (Win32::Process::Open($processHandle, $winpid, 0)) {
	$Forks::Super::OS::SET_PROCESS_AFFINITY = 1;
	$processHandle->SetProcessAffinityMask($n);
	$Forks::Super::OS::SET_PROCESS_AFFINITY = 0;
      } else {
	carp "Forks::Super::Job::config_os_child(): ",
	  "Win32::Process::Open call failed for Windows PID $winpid, ",
	  "can not update CPU affinity\n";
      }
    } elsif ($^O=~/linux/i && Forks::Super::Config::CONFIG("/bin/taskset")) {
      $n = sprintf "0%o", $n;
      system(Forks::Super::Config::CONFIG("/bin/taskset"),"-p",$n,$$);
    } elsif ($^O eq "MSWin32" && Forks::Super::Config::CONFIG("Win32::API")) {
      my $win32_thread_api = _get_win32_thread_api();
      if (!defined $win32_thread_api->{"_error"}) {
	my $thread_id = $win32_thread_api->{"GetCurrentThreadId"}->Call();
	my ($handle, $old_affinity);
	if ($thread_id) {
	  # is 0x0060 right for all versions of Windows ??
	  $handle = $win32_thread_api->{"OpenThread"}->Call(0x0060, 0, $thread_id);
	}
	if ($handle) {
	  $old_affinity = $win32_thread_api->{"SetThreadAffinityMask"}->Call($handle, $n);
	  if ($job->{debug}) {
	    debug("CPU affinity for Win32 thread id $thread_id: ",
		  "$old_affinity ==> $n\n");
	  }
	} else {
	  carp "Forks::Super::Job::config_os_child(): ",
	    "Invalid handle for Win32 thread id $thread_id\n";
	}
      }
    } elsif (Forks::Super::Config::CONFIG('BSD::Process::Affinity')) {
      # this code is not tested and not guaranteed to work
      my $z = eval 'BSD::Process::Affinity->get_process_mask()
                    ->from_bitmask($n)->update()';
      if ($@ && 0 == $Forks::Super::Job::WARNED_ABOUT_AFFINITY++) {
	warn "Forks::Super::Job::config_os_child(): ",
	  "cannot update CPU affinity\n";
      }
    } elsif (0 == $Forks::Super::Job::WARNED_ABOUT_AFFINITY++) {
      warn "Forks::Super::Job::config_os_child(): ",
	"cannot update CPU affinity\n";
    }
  }
  return;
}

sub _get_win32_thread_api {
  if (!$Forks::Super::Job::WIN32_THREAD_API_INITIALIZED) {
    local $! = undef;
    my $win32_thread_api = 
      # needed for setting CPU affinity
      { "GetCurrentThreadId" =>
		Win32::API->new('kernel32','int GetCurrentThreadId()'),
	"OpenThread" =>
		Win32::API->new('kernel32', 
				q[HANDLE OpenThread(DWORD a,BOOL b,DWORD c)]),
	"SetThreadAffinityMask" =>
		Win32::API->new('kernel32',
				"DWORD SetThreadAffinityMask(HANDLE h,DWORD d)"),

	# needed for setting thread priority
	"SetThreadPriority" =>
		Win32::API->new('kernel32', "BOOL SetThreadPriority(HANDLE h,int n)"),
      };
    if ($!) {
      $win32_thread_api->{"_error"} = "$! / $^E";
    }

    undef $!;
    $win32_thread_api->{"GetProcessAffinityMask"} =
      Win32::API->new('kernel32', "BOOL GetProcessAffinityMask(HANDLE h,PDWORD a,PDWORD b)");
    $win32_thread_api->{"GetThreadPriority"} =
      Win32::API->new('kernel32', "int GetThreadPriority(HANDLE h)");

    if ($win32_thread_api->{"_error"}) {
      carp "Forks::Super::Job::_get_win32_thread_api: ",
	"error in Win32::API thread initialization: ",
	$win32_thread_api->{"_error"}, "\n";
    }
    $Forks::Super::Job::WIN32_THREAD_API = $win32_thread_api;
    $Forks::Super::Job::WIN32_THREAD_API_INITIALIZED++;
  }
  return $Forks::Super::Job::WIN32_THREAD_API;
}

1;
