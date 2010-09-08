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
use Forks::Super::Util ':IS_OS';
use Carp;
use base 'Exporter';
use strict;
use warnings;

if (!&IS_WIN32 && !&IS_CYGWIN) {
  Carp::confess "Loaded Win32-only module into \$^O=$^O!\n";
}

# Starting point for details about the Windows Process and
# Thread API:
#   http://msdn.microsoft.com/en-us/library/ms684847(VS.85).aspx


our @EXPORT = ();
our %EXPORT_TAGS = ('all' => [ @EXPORT ]);
our $VERSION = $Forks::Super::Job::VERSION;

our ($_THREAD_API, $_THREAD_API_INITIALIZED, %SYSTEM_INFO);
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
     'ResumeThread' => [ 'kernel32', 'DWORD ResumeThread(HANDLE h)' ],
     'SetProcessAffinityMask' => [ 'kernel32',
		'BOOL SetProcessAffinityMask(HANDLE h,DWORD m)' ],
     'SetThreadAffinityMask' => [ 'kernel32',
		'DWORD SetThreadAffinityMask(HANDLE h,DWORD d)' ],
     'SetThreadPriority' => [ 'kernel32',
		'BOOL SetThreadPriority(HANDLE h,int n)' ],
     'SuspendThread' => [ 'kernel32', 'DWORD SuspendThread(HANDLE h)' ],
     'TerminateThread' => [ 'kernel32',
	        'BOOL TerminateThread(HANDLE h,DWORD x)' ],
    );

# *Forks::Super::Job::OS::get_number_of_processors = *get_number_of_processors;

######################################################################

sub win32api {
  my $function = shift;
  if (!defined $_THREAD_API->{$function}) {
    if (CONFIG('Win32::API')) {
      my $spec = $_WIN32_API_SPECS{$function};
      if (!defined $spec) {
	croak "Forks::Super::Job::OS::Win32: ",
	  "requested unrecognized Win32 API function $function!\n";
      }

      local $! = undef;
      $_THREAD_API->{$function} = Win32::API->new(@$spec);
      if ($!) {
	$_THREAD_API->{'_error'} = "$! / $^E";
      }
    } else {
      return;
    }
  }
  return $_THREAD_API->{$function}->Call(@_);
}

sub get_thread_handle {
  my $thread_id = shift;
  my $set_info = shift || '';

  if (!defined $thread_id) {
    $thread_id = win32api('GetCurrentThreadId');
  }
  $thread_id = abs($thread_id);

  # Thread access rights:
  # from http://msdn.microsoft.com/en-us/library/ms686769(VS.85).aspx
  #
  # 0x0020: THREAD_QUERY_INFORMATION
  # 0x0400: THREAD_QUERY_LIMITED_INFORMATION
  # 0x0040: THREAD_SET_INFORMATION
  # 0x0200: THREAD_SET_LIMITED_INFORMATION

  if ($set_info =~ /term/i) { # need terminate privilege
    # 0x0001: THREAD_TERMINATE
    return 0
      || win32api('OpenThread', 0x0001, 0, $thread_id);
  }
  if ($set_info =~ /susp/i) { # need suspend-resume privilege
    # 0x0002: THREAD_SUSPEND_RESUME
    return 0
      || win32api('OpenThread', 0x0002, 0, $thread_id);
  }

  return 0
    || win32api('OpenThread', 0x0060, 1, $thread_id)
    || win32api('OpenThread', 0x0600, 1, $thread_id)
    || win32api('OpenThread', $set_info ? 0x0040 : 0x0020, 1, $thread_id)
    || win32api('OpenThread', $set_info ? 0x0200 : 0x0400, 1, $thread_id);
}

sub get_process_handle {
  my $process_id = shift;
  my $set_info = shift || 0;

  if (!defined $process_id) {
    # on Cygwin,  GetCurrentProcessId() != $$
    $process_id = win32api('GetCurrentProcessId');
  }

  # Process access rights:
  # from http://msdn.microsoft.com/en-us/library/ms684880(VS.85).aspx
  # If there is a reason the these values are inconsistent with the
  # THREAD_xxx_INFORMATION values, nobody knows what it is.
  #
  # 0x0400: PROCESS_QUERY_INFORMATION
  # 0x1000: PROCESS_QUERY_LIMITED_INFORMATION
  # 0x0200: PROCESS_SET_INFORMATION
  return win32api('OpenProcess', 0x0600, 0, $process_id)
    || win32api('OpenProcess', 0x1200, 0, $process_id)
    || win32api('OpenProcess', $set_info ? 0x0200 : 0x0400, 0, $process_id)
    || ($set_info == 0 && win32api('OpenProcess', 0x1000, 0, $process_id));
}

sub get_thread_priority {
  my $thread_id = shift;
  if (!defined $thread_id) {
    $thread_id = win32api('GetCurrentThreadId');
  }
  my $handle = get_thread_handle($thread_id);
  local $! = undef;
  my $p = win32api('GetThreadPriority', $handle);
  if ($!) {
    carp "Problem retrieving priority for Windows thread $thread_id: ",
      "$! / $^E\n";
  }
  return $p;
}

sub set_thread_priority {
  my ($thread_id, $priority) = @_;
  if (!defined $thread_id) {
    $thread_id = win32api('GetCurrentThreadId');
  }
  my $handle = get_thread_handle($thread_id);
  return 0 unless $handle;
  return win32api('SetThreadPriority', $handle, $priority);
}

sub set_os_priority {
  my ($job, $priority) = @_;
  my $thread_id = get_current_thread_id();
  my $handle = get_thread_handle($thread_id);
  if (!$handle) {
    carp_once "Forks::Super::Job::OS::set_os_priority: ",
      "no Win32 handle available for thread\n";
    return;
  }
  if ($priority > -15 && $priority < -7) {
    $priority = -7;
  }
  if ($priority > 6 && $priority < 15) {
    $priority = 6;
  }
  if (($priority >= -7 && $priority < -2)
	|| ($priority > 2 && $priority <= 6)) {

    my $priority_class = Forks::Super::Job::OS::Win32::get_process_priority_class();
    if (!defined $priority_class) {
      return;
    }
    if ($priority_class != 0x0100) { # 0x0100: REALTIME_PRIORITY_CLASS
      if ($priority < -2) {
	$priority = -2;
      } elsif ($priority > 2) {
	$priority = 2;
      }
    }
  }

  local $! = 0;
  my $result = Forks::Super::Job::OS::Win32::set_thread_priority($thread_id,$priority);
  if ($result) {
    if ($job->{debug}) {
      debug("updated thread priority to $priority for job $$");
    }
    return $result + $priority / 100;
  } else {
    carp "Forks::Super::Job: set os_priority failed: $! / $^E\n";
  }
}

sub get_process_priority_class { # for the current process
  my $phandle = get_process_handle(undef, 0);
  return if !$phandle;
  local $! = 0;
  my $result = win32api('GetPriorityClass', $phandle);
  if ($!) {
    carp_once "Forks::Super::Job::OS: ",
      "Error retrieving current process priority class $! / $^E\n";
  }
  return $result;
}

sub get_current_thread_id {
  local $! = 0;
  my $result = win32api('GetCurrentThreadId');
  return $result;
}

#############################################################################

sub terminate_thread {
  my ($thread_id) = @_;
  my $handle = get_thread_handle($thread_id, 'terminate');
  return 0 unless $handle;
  local $! = 0;
  my $result = win32api('TerminateThread', $handle, 0);
  if ($!) {
    carp "Forks::Super::Job::OS::Win32::terminate_thread(): $! / $^E";
  }
  return $result;
}

sub suspend_thread {
  my ($thread_id) = @_;
  my $handle = get_thread_handle($thread_id, 'suspend');
  return 0 unless $handle;

  local $! = 0;
  my $result = win32api('SuspendThread', $handle);
  if ($!) {
    carp "Forks::Super::Job::OS::Win32::suspend_thread(): $! / $^E";
  }
  return $result > -1;
}

sub resume_thread {
  my ($thread_id) = @_;
  my $handle = get_thread_handle($thread_id, 'suspend');
  return 0 unless $handle;

  local $! = 0;
  # Win32 threads maintain a "suspend count". If you call
  # SuspendThread on a thread five times, you have to call
  # ResumeThread five times to reactivate it.
  my $result;
  do {
    $result = win32api('ResumeThread', $handle);
  } while ($result > 1);
  if ($!) {
    carp "Forks::Super::Job::OS::Win32::resume_thread(): $! / $^E";
  }
  return $result > -1;
}

######################################################################

sub get_system_info {
  # XXX - will this work on all versions of Windows? Somehow I doubt it
  if (0 == scalar keys %SYSTEM_INFO && CONFIG('Win32::API')) {
    if (!defined $_THREAD_API->{'GetSystemInfo'}) {
      my $is_wow64 = 0;
      my $lpsystem_info_avail = Win32::API::Type::is_known('LPSYSTEM_INFO');
      my $proto = sprintf 'BOOL %s(%s i)',
	$is_wow64 ? 'GetNativeSystemInfo' : 'GetSystemInfo',
	$lpsystem_info_avail ? 'LPSYSTEM_INFO' : 'PCHAR';
      $_THREAD_API->{'GetSystemInfo'} = Win32::API->new('kernel32', $proto);
    }
    my $buffer = chr(0) x 36;
    $_THREAD_API->{'GetSystemInfo'}->Call($buffer);

    ($SYSTEM_INFO{'PageSize'},
     $SYSTEM_INFO{'MinimumApplicationAddress'},
     $SYSTEM_INFO{'MaximumApplicationAddress'},
     $SYSTEM_INFO{'ActiveProcessorMask'},
     $SYSTEM_INFO{'NumberOfProcessors'},
     $SYSTEM_INFO{'ProcessorType'},
     $SYSTEM_INFO{'AllocationGranularity'},
     $SYSTEM_INFO{'ProcessorLevel'},
     $SYSTEM_INFO{'ProcessorType'})
      = unpack('VVVVVVVvv', substr($buffer,4));
  }
  return %SYSTEM_INFO;
}

sub open_win32_process {
  my ($job) = @_;
  my $cmd = join ' ', @{$job->{cmd}};
  my $pid = open my $proch, "-|", "$cmd";
  Win32::Process::Open($Forks::Super::Job::WIN32_PROC, $pid, 0);
  $Forks::Super::Job::WIN32_PROC_PID = $pid;

  # if desired, this is the place to set OS priority,
  # process CPU affinity, other OS features.
  if (defined $job->{cpu_affinity}) {
    $Forks::Super::Job::WIN32_PROC->SetProcessAffinityMask(
		$job->{cpu_affinity});
  }
  CORE::waitpid $pid, 0;
  my $c1 = $?;
  debug("Exit code of $$ was $c1") if $job->{debug};
  return $c1;
}

sub open2_win32_process {
  my ($job) = @_;
  my $cmd = join ' ', @{$job->{cmd}};
  my $pid = open my $proch, "|-", "$cmd";
  Win32::Process::Open($Forks::Super::Job::WIN32_PROC, $pid, 0);
  $Forks::Super::Job::WIN32_PROC_PID = $pid;

  # if desired, this is the place to set OS priority,
  # process CPU affinity, other OS features.
  if (defined $job->{cpu_affinity}) {
    $Forks::Super::Job::WIN32_PROC->SetProcessAffinityMask(
		$job->{cpu_affinity});
  }
  CORE::waitpid $pid, 0;
  my $c1 = $?;
  debug("Exit code of $$ was $c1") if $job->{debug};
  return $c1;
}

# XXX - doesn't work, doesn't handoff redirected filehandles properly
sub create_win32_process {
  my ($job) = @_;
  my $cmd = join ' ', @{$job->{cmd}};
  my ($appname) = split /\s+/, $cmd; # XXX - not idiot proof
  $Forks::Super::Job::WIN32_PROC = '';
  Win32::Process::Create($Forks::Super::Job::WIN32_PROC,
			 $appname,
			 $cmd,
			 1,0,'.');
  $Forks::Super::Job::WIN32_PROC_PID
    = $Forks::Super::Job::WIN32_PROC->GetProcessID();
  if (defined $job->{cpu_affinity}) {
    $Forks::Super::Job::WIN32_PROC->SetProcessAffinityMask(
		$job->{cpu_affinity});
  }
  CORE::waitpid $Forks::Super::Job::WIN32_PROC_PID, 0;
  my $c1 = $?;
  debug("Exit code of $$ was $c1") if $job->{debug};
  return $c1;
}

sub system_win32_process {
  my ($job) = @_;
  $Forks::Super::Job::WIN32_PROC = '__z__';
  $ENV{'__FORKS_SUPER_PARENT_THREAD'} = $$;
  # no way to update cpu affinity, priority with this method
  my $c1 = system( @{$job->{cmd}} );
  $Forks::Super::Job::WIN32_PROC = undef;
  return $c1;
}

sub open3_win32_process {
  my ($job) = @_;
  my $cmd = join ' ', @{$job->{cmd}};
  my $pid = open my $proch, '|-', $cmd;
  $Forks::Super::Job::WIN32_PROC_PID = $pid;
  $Forks::Super::Job::WIN32_PROC = '__open3__';

  if (defined $job->{cpu_affinity} && CONFIG('Sys::CpuAffinity')) {
    Sys::CpuAffinity::setAffinity($pid, $job->{cpu_affinity});
  }

  close $proch;
  my $c1 = $?;
  $Forks::Super::Job::WIN32_PROC = undef;
  return $c1;
}

1;
