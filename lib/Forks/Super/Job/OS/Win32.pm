#
# Forks::Super::Job::OS::Win32 - operating system manipulation for
#          Windows (and sometimes Cygwin)
#
# It is hard to test all the different possible OS-versions
# (98,2000,XP,Vista,7,...) and different configurations
# (32- vs 64-bit, for one), so expect this module to be
# incomplete, to not always do things in the best way or all
# systems. The highest ambitions for this module are to not
# cause too many general protection faults and to fail gracefully.
#

package Forks::Super::Job::OS::Win32;
use Forks::Super::Config qw(:all);
use Forks::Super::Debug qw(:all);
use Carp;
use base 'Exporter';
use strict;
use warnings;

if ($^O ne "MSWin32" && $^O ne "cygwin") {
  croak "Loaded Win32-only module into \$^O=$^O!\n";
}

# Starting point for details about the Windows Process and
# Thread API:
#   http://msdn.microsoft.com/en-us/library/ms684847(VS.85).aspx


our $VERSION = $Forks::Super::Job::VERSION;
our @EXPORT = ();
our %EXPORT_TAGS = ('all' => [ @EXPORT ]);

our ($_THREAD_API, $_THREAD_API_INITIALIZED);
our %_WIN32_API_SPECS
  = ('GetActiveProcessorCount' => [ 'kernel32',
		'DWORD GetActiveProcessorCount(WORD g)' ],
     'GetCurrentProcess' => [ 'kernel32',
		'HANDLE GetCurrentProcess()' ],
     'GetCurrentProcessId' => [ 'kernel32',
		'DWORD GetCurrentProcessId()' ],
     'GetCurrentThread' => [ 'kernel32',
		'HANDLE GetCurrentThread()' ],
     'GetCurrentThreadId' => [ 'kernel32', 
		'int GetCurrentThreadId()' ],
     'GetLastError' => [ 'kernel32', 'DWORD GetLastError()' ],
     'GetPriorityClass' => [ 'kernel32',
	        'DWORD GetPriorityClass(HANDLE h)' ],
     'GetProcessAffinityMask' => [ 'kernel32',
		'BOOL GetProcessAffinityMask(HANDLE h,PDWORD a,PDWORD b)' ],
     'GetThreadPriority' => [ 'kernel32',
		'int GetThreadPriority(HANDLE h)' ],
     'OpenProcess' => [ 'kernel32', 
		'HANDLE OpenProcess(DWORD a,BOOL b,DWORD c)' ],
     'OpenThread' => [ 'kernel32', 
		'HANDLE OpenThread(DWORD a,BOOL b,DWORD c)' ],
     'SetProcessAffinityMask' => [ 'kernel32',
		'BOOL SetProcessAffinityMask(HANDLE h,DWORD m)' ],
     'SetThreadAffinityMask' => [ 'kernel32',
		'DWORD SetThreadAffinityMask(HANDLE h,DWORD d)' ],
     'SetThreadPriority' => [ 'kernel32',
		'BOOL SetThreadPriority(HANDLE h,int n)' ],
     'TerminateThread' => [ 'kernel32',
	        'BOOL TerminateThread(HANDLE h,DWORD x)' ],
    );

*Forks::Super::Job::OS::set_os_priority = *set_os_priority;
*Forks::Super::Job::OS::set_cpu_affinity = *set_cpu_affinity;
*Forks::Super::Job::OS::get_cpu_load = *get_cpu_load;
*Forks::Super::Job::OS::get_number_of_processors = *get_number_of_processors;

######################################################################

sub win32api {
  my $function = shift;
  if (!defined $_THREAD_API->{$function} && CONFIG("Win32::API")) {
    my $spec = $_WIN32_API_SPECS{$function};
    if (!defined $spec) {
      croak "Forks::Super::Job::OS::Win32: ",
	"requested unrecognized Win32 API function $function!\n";
    }

    local $! = undef;
    $_THREAD_API->{$function} = Win32::API->new(@$spec);
    if ($!) {
      $_THREAD_API->{"_error"} = "$! / $^E";
    }
  }
  return $_THREAD_API->{$function}->Call(@_);
}

sub get_thread_handle {
  my $thread_id = shift;
  my $set_info = shift || 0;

  if (!defined $thread_id) {
    $thread_id = win32api("GetCurrentThreadId");
  }
  $thread_id = abs($thread_id);

  # Thread access rights:
  # from http://msdn.microsoft.com/en-us/library/ms686769(VS.85).aspx
  #
  # 0x0020: THREAD_QUERY_INFORMATION
  # 0x0400: THREAD_QUERY_LIMITED_INFORMATION
  # 0x0040: THREAD_SET_INFORMATION
  # 0x0200: THREAD_SET_LIMITED_INFORMATION
  return 0
    || win32api("OpenThread", 0x0060, 0, $thread_id)
    || win32api("OpenThread", 0x0600, 0, $thread_id)
    || win32api("OpenThread", $set_info ? 0x0040 : 0x0020, 0, $thread_id)
    || win32api("OpenThread", $set_info ? 0x0200 : 0x0400, 0, $thread_id);
}

sub get_process_handle {
  my $process_id = shift;
  my $set_info = shift || 0;

  if (!defined $process_id) {
    # on Cygwin,  GetCurrentProcessId() != $$
    $process_id = win32api("GetCurrentProcessId");
  }

  # Process access rights:
  # from http://msdn.microsoft.com/en-us/library/ms684880(VS.85).aspx
  # If there is a reason the these values are inconsistent with the
  # THREAD_xxx_INFORMATION values, nobody knows what it is.
  #
  # 0x0400: PROCESS_QUERY_INFORMATION
  # 0x1000: PROCESS_QUERY_LIMITED_INFORMATION
  # 0x0200: PROCESS_SET_INFORMATION
  return win32api("OpenProcess", 0x0600, 0, $process_id)
    || win32api("OpenProcess", 0x1200, 0, $process_id)
    || win32api("OpenProcess", $set_info ? 0x0200 : 0x0400, 0, $process_id)
    || ($set_info == 0 && win32api("OpenProcess", 0x1000, 0, $process_id));
}

sub get_thread_priority {
  my $thread_id = shift;
  my $handle = get_thread_handle($thread_id);
  local $! = undef;
  my $p = win32api("GetThreadPriority", $handle);
  if ($!) {
    carp "Problem retrieving priority for Windows thread $thread_id: ",
      "$! / $^E\n";
  }
  return $p;
}

######################################################################

sub set_os_priority {
  my ($job) = @_;
  my $priority = $job->{os_priority};

  if ($priority < -15 || $priority > 15) {
    carp "Forks::Super::Job: os_priority was $priority. ",
      "On Windows it must be a value between -15 and 15.\n";
    return;
  }

  return _set_os_priority_with_w32api($job,$priority)
    || Forks::Super::Job::OS::set_os_priority_generic($job);
}

sub _set_os_priority_with_w32api {
  my ($job,$priority) = @_;
  if (CONFIG("Win32::API")) {
    my $thread_id = win32api("GetCurrentThreadId");
    my ($handle, $old_affinity);
    if ($thread_id) {
      $handle = get_thread_handle($thread_id);
    }
    if (!defined $handle) {
      carp "Forks::Super::Job: no Win32 handle avail for thread $thread_id\n";
      return 0;
    }

    if ($priority > -15 && $priority < -7) {
      $priority = -7;
    }
    if ($priority > 6 && $priority < 15) {
      $priority = 6;
    }
    if (($priority >= -7 && $priority < -2)
	|| ($priority > 2 && $priority <= 6)) {
	# these ranges only allowed for REALTIME_PRIORITY_CLASS

      my $phandle = get_process_handle(undef,0);
      if ($phandle) {
	my $priority_class = win32api("GetPriorityClass", $phandle);
	if ($priority_class != 0x0100) {
	  if ($priority < -2) {
	    $priority = -2;
	  } elsif ($priority > 2) {
	    $priority = 2;
	  }
	}
      }
    }

    my $result = win32api("SetThreadPriority", $handle, $priority);
    if ($result) {
      if ($job->{debug}) {
	debug("updated thread priority to $priority for job $$");
      }
      return 1;
    } else {
      carp "Forks::Super::Job: set os_priority failed: $! / $^E\n";
    }
  }
  return 0;
}

######################################################################

sub set_cpu_affinity {
  my ($job) = @_;
  my $bitmask = $job->{cpu_affinity};

  if ($bitmask == 0) {
    carp "Forks::Super::Job::config_os_child(): ",
      "desired cpu affinity set to zero. Is that what you really want?\n";
    return 1;
  }

  return _set_cpu_affinity_with_w32api($job)
    || _set_cpu_affinity_with_win32_process($job)
    || Forks::Super::Job::OS::set_cpu_affinity_generic($job);
}

sub _set_cpu_affinity_with_win32_process {
  my $job = shift;
  my $n = $job->{cpu_affinity};
  if (!CONFIG("Win32::Process")) {
    return 0;
  }
  if ($^O ne "cygwin") {
    return 0;
  }
  my $winpid = Win32::Process::GetCurrentProcessID();
  my $processHandle;

  local $SIG{SEGV} = sub {
      $Forks::Super::OS::SET_PROCESS_AFFINITY = -1;
      warn "********************************************************\n",
	   "* Forks::Super: set CPU affinity failed:               *\n",
	   "* Win32::Process::SetAffinityMask() caused a SIGSEGV.  *\n",
	   "* Recommend upgrading to at least Win32::Process v0.14 *\n",
	   "********************************************************\n";
    };
  if (!defined $winpid) {
    carp "Forks::Super::Job::config_os_child(): ",
      "Win32::Process::GetCurrentProcessID() returned <undef>\n";
    return 0;
  }
  if (Win32::Process::Open($processHandle, $winpid, 0)) {
    $Forks::Super::OS::SET_PROCESS_AFFINITY = 1;
    $processHandle->SetProcessAffinityMask($n);
    if ($Forks::Super::OS::SET_PROCESS_AFFINITY == -1) {
      return 0;
    }
    $Forks::Super::OS::SET_PROCESS_AFFINITY = 0;
    return 1;
  }
  carp "Forks::Super::Job::config_os_child(): ",
    "Win32::Process::Open call failed for Windows PID $winpid, ",
      "can not update CPU affinity\n";
  return 0;
}


sub _set_cpu_affinity_with_w32api {
  my $job = shift;
  my $bitmask = $job->{cpu_affinity};

  if (!CONFIG("Win32::API")) {
    return 0;
  }

  # this method is used by both Cygwin and MSWin32.
  # In Cygwin, we want to set the PROCESS affinity mask
  # In MSWin32, we want to set the THREAD affinity mask

  # In addition, on MSWin32 where we will call
  # Win32::Process::Create, we will want to set the
  # PROCESS affinity mask after the Create call.

  local $! = undef;
  local $^E;
  if ($^O =~ /cygwin/i) {
    my $phandle = get_process_handle(undef, 1);
    if (!defined $phandle || $phandle == 0) {
      carp "Forks::Super::Job::config_os_child: ",
	"failed to set cpu affinity for $$ [1]: $! / $^E\n";
      return 0;
    }
    my $result = win32api("SetProcessAffinityMask", $phandle, $bitmask);
    if ($result == 0) {
      my $last_error = win32api("GetLastError");
      $result = "$last_error / $! / $^E";
      carp "Forks::Super::Job::config_os_child: ",
	"failed to set cpu affinity for $$ [2]: $result\n";
    }
    return $result;
  }

  my $thread_id = abs($$);
  my $thandle = get_thread_handle(undef, 1);
  if (!defined $thandle || $thandle == 0) {
    carp "Forks::Super::Job::config_os_child: ",
      "failed to set cpu affinity for $$ [3]: $! / $^E\n";
    return 0;
  }
  my $previous_affinity 
    = win32api("SetThreadAffinityMask", $thandle, $bitmask);
  if ($previous_affinity == 0) {
    carp "Forks::Super::Job::config_os_child: ",
      "failed to set cpu affinity for $$ [4]: $! / $^E\n";
    return 0;
  }
  return $previous_affinity;
}

sub set_cpu_affinity_for_win32_process {
  my $process = shift;    # Win32::Process object
  my $bitmask = shift;

  if ($bitmask == 0) {
    carp "Forks::Super::Job::config_child_os: ",
      "ignoring cpu affinity mask of zero (Is that what you want?)\n";
    return 0;
  }
  if ($process->SetProcessAffinityMask($bitmask)) {
    return 1;
  }


  my $pid = $process->GetProcessID();

  my $phandle = get_process_handle($pid, 1);
  if (defined $phandle && $phandle != 0) {
    carp "Forks::Super::Job: ",
      "failed to adjust cpu affinity for new Windows Process $pid\n";
    return 0;
  }
  my $result = win32api("SetProcessAffinityMask", $phandle, $bitmask);
  if ($result == 0) {
    my $last_error = win32api("GetLastError");
    $result = "$last_error / $! / $^E";
    carp "Forks::Super::Job::config_os_child: ",
      "failed to set cpu affinity for $$ [2]: $result\n";
    return 0;
  }
  return 1;
}

######################################################################

sub get_number_of_processors {
  if (defined $ENV{NUMBER_OF_PROCESSORS}) {
    return $ENV{NUMBER_OF_PROCESSORS};
  }

  my %system_info = get_system_info();
  if (defined $system_info{"NumberOfProcessors"}) {
    return $system_info{"NumberOfProcessors"};
  }

  return Forks::Super::Job::OS::get_number_of_processors_generic();
}

######################################################################

sub _get_cpu_load_with_win32_systeminfo_cpuusage {
  if (CONFIG("Win32::SystemInfo::CpuUsage")) {
    my $usage = Win32::SystemInfo::CpuUsage::getCpuUsage(1000) * 0.01;
    if ($usage eq "0") {
      $usage = "0.00"; # zero but true
    }
    return $usage;
  }
  return 0;
}

sub _get_cpu_load_with_win32_process_cpuusage {
  if (CONFIG("Win32::Process::CpuUsage")) {
    my $usage = Win32::Process::CpuUsage::getSystemCpuUsage(1000) * 0.01;
    if ($usage eq "0") {
      $usage = "0.00"; # zero but true
    }
    return $usage;
  }
  return 0;
}

sub get_cpu_load {
  return _get_cpu_load_with_win32_systeminfo_cpuusage()
    || _get_cpu_load_with_win32_process_cpuusage()
    || -1.0;
}

our %SYSTEM_INFO = ();
sub get_system_info {
  # XXX - will this work on all versions of Windows? Somehow I doubt it
  if (0 == scalar keys %SYSTEM_INFO && CONFIG("Win32::API")) {
    if (!defined $_THREAD_API->{"GetSystemInfo"}) {
      my $is_wow64 = 0;
      my $lpsystem_info_avail = Win32::API::Type::is_known("LPSYSTEM_INFO");
      my $proto = sprintf 'BOOL %s(%s i)',
	$is_wow64 ? 'GetNativeSystemInfo' : 'GetSystemInfo',
	$lpsystem_info_avail ? 'LPSYSTEM_INFO' : 'PCHAR';
      $_THREAD_API->{"GetSystemInfo"} = Win32::API->new('kernel32', $proto);
    }
    my $buffer = chr(0) x 36;
    $_THREAD_API->{"GetSystemInfo"}->Call($buffer);

    ($SYSTEM_INFO{"PageSize"},
     $SYSTEM_INFO{"MinimumApplicationAddress"},
     $SYSTEM_INFO{"MaximumApplicationAddress"},
     $SYSTEM_INFO{"ActiveProcessorMask"},
     $SYSTEM_INFO{"NumberOfProcessors"},
     $SYSTEM_INFO{"ProcessorType"},
     $SYSTEM_INFO{"AllocationGranularity"},
     $SYSTEM_INFO{"ProcessorLevel"},
     $SYSTEM_INFO{"ProcessorType"})
      = unpack("VVVVVVVvv", substr($buffer,4));
  }
  return %SYSTEM_INFO;
}

sub kill_process_tree {
  my (@pids) = @_;
  my $count = 0;
  foreach my $pid (@pids) {
    next if !defined $pid || $pid == 0;

    # How many ways are there to kill a process in Windows?
    # How many do you need?

    my $c1 = () = grep { /ERROR/ } `TASKKILL /PID $pid /F /T 2>&1`;
    $c1 = system("TSKILL $pid /A > nul") if $c1;
    if ($c1 && CONFIG("Win32::Process::Kill")) {
      $c1 = !Win32::Process::Kill::Kill($pid);
    }

    if ($c1) {
      my $c2 = () = `TASKLIST /FI \"pid eq $pid\" 2> nul`;
      if ($c2 == 0) {
	warn "Forks::Super::Job::OS::Win32::kill_process_tree: ",
	  "$pid: no such process?\n";
      }
    }
    $count += !$c1;
  }
  return $count;
}

######################################################################

# Windows API specifies some other things we could control,
# though I don't know what all of them are.
#
# SetProcessShutdownParameters
# SetThreadIdealProcessor
# SetThreadStackGuarantee
# SetUmsThreadInformation
# ...
#

1;
