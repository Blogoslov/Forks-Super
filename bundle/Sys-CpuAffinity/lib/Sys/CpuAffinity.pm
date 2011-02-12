package Sys::CpuAffinity;
use Carp;
use warnings;
use strict;
use base qw(DynaLoader);

our $VERSION = '0.99';
our $DEBUG = $ENV{DEBUG} || 0;
eval { bootstrap Sys::CpuAffinity $VERSION };

sub import {
}

sub _maskToArray {
    my ($mask) = @_;
    my @mask = ();
    my $i = 0;
    while ($mask > 0) {
        push @mask, $i if $mask & 1;
	$i++;
	$mask >>= 1;
    }
    return @mask;
}

sub _arrayToMask {
    my $mask = 0;
    $mask |= (1 << $_) for @_;
    return $mask;
}



# does 1<<32 equal 1 or 4294967296 on this system?
# when it's 1, we need to say 2**$np instead of 1<<$np
our $_INT32 = !(1 - (1 << 32));

#
# Development guide:
#
# when you figure out a new way to perform a task
# (in this case, getting cpu affinity), write the method and insert
# the call into the chain here.
#
# Methods should be named  _getAffinity_with_XXX, _setAffinity_with_XXX,
# or _getNumCpus_from_XXX. The t/inventory.pl file will identify these
# methods so they can be included in the tests.
#
# The new method should return false (0 or '' or undef) whenever it
# knows it is the wrong tool for the current system or any other time
# that it can't figure out the answer.
#
# For XS-based solutions, the stub will go in the distributions
# contrib/  directory, and will be available if it successfully
# compiles during the installation process. See 
# _getAffinity_with_xs_sched_getaffinity  for an example of
# how to use a compiled function.
#
# Methods that might return with the wrong answer (for example, methods
# that make a guess) should go toward the end of the chain. This
# probably should include methods that read environment variables
# or methods that rely on external commands as these methods can
# be spoofed.
#

sub getAffinity {
  my ($pid, %flags) = @_; # %flags reserved for future use
  my $wpid = $pid;

  my $mask = 0 
    || _getAffinity_with_taskset($pid)
    || _getAffinity_with_xs_sched_getaffinity($pid)
    || _getAffinity_with_xs_processor_bind($pid)
    || _getAffinity_with_xs_cpuset_getaffinity($pid)
    || _getAffinity_with_BSD_Process_Affinity($pid)
    || _getAffinity_with_cpuset($pid)
    || _getAffinity_with_pbind($pid)
    || _getAffinity_with_xs_win32($pid)
    || _getAffinity_with_Win32Process($wpid)
    || _getAffinity_with_Win32API($wpid)
    || 0;

  return wantarray ? _maskToArray($mask) : $mask;
}

sub setAffinity {
  my ($pid, $mask, %flags) = @_; # %flags reserved for future use
  if (ref $mask eq 'ARRAY') {
    $mask = 0;
    $mask += (2 ** $_) for @{$_[1]};
  }
  my $np = getNumCpus();
  if ($mask == -1) {
    if ($np > 0) {
      $mask = (2 ** $np) - 1;
    }
  }
  if ($mask <= 0) {
    carp "Sys::CpuAffinity: invalid mask $mask in call to setAffinty\n";
    return;
  }

  # http://www.cpantesters.org/cpan/report/07107190-b19f-3f77-b713-d32bba55d77f
  # 1 << 32 == 1  caused test failure in v0.90

  my $maxmask = 1 << $np;
  if ($maxmask > 1 && $mask >= $maxmask) {
    my $newmask = $mask & ($maxmask - 1);
    if ($newmask == 0) {
      carp "Sys::CpuAffinity: mask $mask is not valid for system with ",
	"$np processors.\n";
      return;
    } else {
      carp "Sys::CpuAffinity: mask $mask adjusted to $newmask for ",
	"system with $np processors\n";
      $mask = $newmask;
    }
  }

  return _setAffinity_with_Win32API($pid,$mask)
    || _setAffinity_with_xs_win32($pid,$mask)
    || _setAffinity_with_Win32Process($pid,$mask)
    || _setAffinity_with_taskset($pid,$mask)
    || _setAffinity_with_xs_sched_setaffinity($pid,$mask)
    || _setAffinity_with_BSD_Process_Affinity($pid,$mask)
    || _setAffinity_with_xs_cpuset_setaffinity($pid,$mask)  # XXX needs wor
    || _setAffinity_with_xs_processor_bind($pid,$mask)
    || _setAffinity_with_bindprocessor($pid,$mask)
    || _setAffinity_with_cpuset($pid,$mask)
    || _setAffinity_with_pbind($pid,$mask)
#   || _setAffinity_with_psrset($pid,$mask) # XXX needs proper test e
    || 0;
}

our $_NUM_CPUS_CACHED = 0;
sub getNumCpus() {
  if ($_NUM_CPUS_CACHED) {
    return $_NUM_CPUS_CACHED;
  }
  return $_NUM_CPUS_CACHED =
       _getNumCpus_from_Win32API()
    || _getNumCpus_from_Win32API_System_Info()
    || _getNumCpus_from_xs_Win32API_System_Info()
    || _getNumCpus_from_xs_cpusetGetCPUCount()
    || _getNumCpus_from_proc_cpuinfo()
    || _getNumCpus_from_proc_stat()
    || _getNumCpus_from_bindprocessor()
    || _getNumCpus_from_dmesg_bsd()
    || _getNumCpus_from_dmesg_solaris()
    || _getNumCpus_from_sysctl()
    || _getNumCpus_from_psrinfo()
    || _getNumCpus_from_hinv()
    || _getNumCpus_from_hwprefs()
    || _getNumCpus_from_system_profiler()
    || _getNumCpus_from_prtconf()
    || _getNumCpus_from_Test_Smoke_SysInfo()
    || _getNumCpus_from_ENV()
    || -1;
}

######################################################################

# count processors toolbox

sub _getNumCpus_from_ENV {
  # in some OS, the number of processors is part of the default environment
  # this also makes it easy to spoof the value (is that good or bad?)
  if ($^O eq "MSWin32" || $^O eq "cygwin") {
    if (defined $ENV{NUMBER_OF_PROCESSORS}) {
      _debug("from Windows ENV: nproc=$ENV{NUMBER_OF_PROCESSORS}");
      return $ENV{NUMBER_OF_PROCESSORS};
    }
  }
  return 0;
}

sub _getNumCpus_from_Win32API {
  # GetActiveProcessorCount api function is only supported since Windows 7?
  # !!! Unfortunately, it also seems to make Windows 7 crash !!!
  return 0 if $^O ne "MSWin32" && $^O ne "cygwin";
  return 0 if !_configModule("Win32::API");

  # ALL_PROCESSOR_GROUPS: 0xffff
  ### return _win32api("GetActiveProcessorCount", 0xffff) ||
    0;
}

our %WIN32_SYSTEM_INFO = ();
our %WIN32API = ();
sub _getNumCpus_from_Win32API_System_Info {
  return 0 if $^O ne "MSWin32" && $^O ne "cygwin";
  return 0 if !_configModule("Win32::API");

  if (0 == scalar keys %WIN32_SYSTEM_INFO) {
    if (!defined $WIN32API{"GetSystemInfo"}) {
      my $is_wow64 = 0;
      my $lpsysinfo_type_avail = Win32::API::Type::is_known('LPSYSTEM_INFO');
      my $proto = sprintf 'BOOL %s(%s i)',
	$is_wow64 ? 'GetNativeSystemInfo' : 'GetSystemInfo',
        $lpsysinfo_type_avail ? 'LPSYSTEM_INFO' : 'PCHAR';
      $WIN32API{"GetSystemInfo"} = Win32::API->new('kernel32', $proto);
    }

    # does this part break on 64-bit machines?
    my $buffer = chr(0) x 36;
    $WIN32API{"GetSystemInfo"}->Call($buffer);
    ($WIN32_SYSTEM_INFO{"PageSize"},
     $WIN32_SYSTEM_INFO{"..."},
     $WIN32_SYSTEM_INFO{"..."},
     $WIN32_SYSTEM_INFO{"..."},
     $WIN32_SYSTEM_INFO{"NumberOfProcessors"},
     $WIN32_SYSTEM_INFO{"..."},
     $WIN32_SYSTEM_INFO{"..."},
     $WIN32_SYSTEM_INFO{"..."},
     $WIN32_SYSTEM_INFO{"..."})
      = unpack("VVVVVVVvv", substr($buffer,4));
  }
  return $WIN32_SYSTEM_INFO{"NumberOfProcessors"} || 0;
}

#sub _getNumCpus_from_probe_xs {
#  my @xs_func = grep { /^xs/ } keys %Sys::CpuAffinity::;
#  print "defined xs functions:  @xs_func\n";
#  return 0;  
#}


sub _getNumCpus_from_xs_cpusetGetCPUCount { # NOT TESTED irix
  if (defined &xs_cpusetGetCPUCount) {
    return xs_cpusetGetCPUCount();
  } else {
    return 0;
  }
}

sub _getNumCpus_from_xs_Win32API_System_Info {
  if (defined &xs_get_numcpus_from_windows_system_info) {
    return xs_get_numcpus_from_windows_system_info();
  } elsif (defined &xs_get_numcpus_from_windows_system_info_alt) {
    return xs_get_numcpus_from_windows_system_info_alt();
  } else {
    return 0;
  }
}

sub _getNumCpus_from_proc_cpuinfo {

  # I'm told this could give the wrong answer with a "non-SMP kernel"
  # http://www-oss.fnal.gov/fss/hypermail/archives/hyp-linux/0746.html

  return 0 if ! -r '/proc/cpuinfo';

  my $num_processors = 0;
  my $cpuinfo_fh;
  if (open $cpuinfo_fh, '<', '/proc/cpuinfo') {
    while (<$cpuinfo_fh>) {
      if (/^processor\s/) {
	$num_processors++;
      }
    }
    close $cpuinfo_fh;
  }
  _debug("from /proc/cpuinfo: nproc=$num_processors");
  return $num_processors || 0;
}

sub _getNumCpus_from_proc_stat {

  return 0 if ! -r '/proc/stat';

  my $num_processors = 0;
  my $stat_fh;
  if (open $stat_fh, '<', '/proc/stat') {
    while (<$stat_fh>) {
      if (/^cpu\d/i) {
	$num_processors++;
      }
    }
    close $stat_fh;
    }
  _debug("from /proc/stat: nproc=$num_processors");
  return $num_processors || 0;
}

sub _getNumCpus_from_bindprocessor {
  return 0 if $^O !~ /aix/i;
  return 0 if !_configExternalProgram("bindprocessor");
  my $cmd = _configExternalProgram("bindprocessor");
  my $bindprocessor_output = qx($cmd -q 2> /dev/null);
  $bindprocessor_output =~ s/\s+$//;
  return 0 if !$bindprocessor_output;

  # Typical output: "The available processors are: 0 1 2 3"

  $bindprocessor_output =~ s/.*:\s+//;
  my $num_processors = () = split /\s+/, $bindprocessor_output;
  return $num_processors;
}

sub _getNumCpus_from_dmesg_bsd {
    return 0 if $^O !~ /bsd/i;

    my @dmesg;
    if (-r '/var/run/dmesg.boot') {
	open my $fh, '<', '/var/run/dmesg.boot';
	@dmesg = <$fh>;
	close $fh;
    } else {
	return 0 if !_configExternalProgram("dmesg");

	# on the version of FreeBSD that I have to play with
	# (8.0), dmesg contains this message:
	#
	#       FreeBSD/SMP: Multiprocessor System Detected: 2 CPUs
	#
	# so we'll go with that.

	my $cmd = _configExternalProgram("dmesg");
	@dmesg = `$cmd`;
    }
    my @d = grep { /Multiprocessor System Detected:/i } @dmesg;
    return 0 if @d == 0;
    my ($ncpus) = $d[0] =~ /Detected: (\d+) CPUs/i;
    return $ncpus || 0;
}

sub _getNumCpus_from_dmesg_solaris {
    return 0 if $^O !~ /solaris/i;
    return 0 if !_configExternalProgram("dmesg");
    my $cmd = _configExternalProgram("dmesg");
    my @dmesg = qx($cmd 2>/dev/null);

    # a few clues that I see on my system (opensolaris 5.11 i86pc):
    #      ... blah blah is bound to cpu <n>
    #      ^cpu<n>: x86 blah blah
    my $ncpus = 0;
    foreach my $dmesg (@dmesg) {
	if ($dmesg =~ /is bound to cpu (\d+)/) {
	    $ncpus = $1 + 1 if $ncpus <= $1;
	}
	if ($dmesg =~ /^cpu(\d+):/) {
	    $ncpus = $1 + 1 if $ncpus <= $1;
	}
    }
    return $ncpus;
}

sub _getNumCpus_from_sysctl {
    # sysctl works on a number of systems including MacOS
    return 0 if !_configExternalProgram("sysctl");
    my $cmd = _configExternalProgram("sysctl");
    my @sysctl = qx($cmd -a 2> /dev/null);
    my @results = grep { /^hw.ncpu[:=]/ } @sysctl;
    return 0 if @results == 0;
    my ($ncpus) = $results[0] =~ /[:=]\s*(\d+)/;

    if ($ncpus == 0) {
      $ncpus = 0 + qx($cmd -n hw.ncpu 2> /dev/null);
    }
    if ($ncpus == 0) {
      $ncpus = 0 + qx($cmd -n hw.ncpufound 2> /dev/null);
    }


    return $ncpus || 0;

    # there are also sysctl/sysctlbyname system calls
}

sub _getNumCpus_from_psrinfo {
    return 0 if !_configExternalProgram("psrinfo");
    my $cmd = _configExternalProgram("psrinfo");
    my @info = qx($cmd 2> /dev/null);
    return scalar @info;
}

sub _getNumCpus_from_hinv {   # NOT TESTED irix
  return 0 if $^O =~ /irix/i;
  return 0 if !_configExternalProgram("hinv");
  my $cmd = _configExternalProgram("hinv");

  # found this in Test::Smoke::SysInfo v0.042 in Test-Smoke-1.43 module
  my @processor = qx($cmd -c processor);
  _debug("\"hinv -c processor\" output: ", @processor);
  my ($cpu_cnt) = grep /\d+.+processors?$/i, @processor;
  my $ncpu = (split " ", $cpu_cnt)[0];
  return $ncpu;
}


sub _getNumCpus_from_hwprefs {   # NOT TESTED darwin
  return 0 if $^O !~ /darwin/i && $^O !~ /MacOS/i;
  return 0 if !_configExternalProgram("hwprefs");
  my $cmd = _configExternalProgram("hwprefs");
  my $result = qx($cmd cpu_count 2>/dev/null);
  $result =~ s/\s+$//;
  _debug("\"$cmd cpu_count\" output: ", $result);
  return $result || 0;
}

sub _getNumCpus_from_system_profiler {  # NOT TESTED darwin
  return 0 if $^O !~ /darwin/ && $^O !~ /MacOS/i;
  return 0 if !_configExternalProgram("system_profiler");

  # with help from Test::Smoke::SysInfo
  my $cmd = _configExternalProgram("system_profiler");
  my $system_profiler_output 
    = qx($cmd -detailLevel mini SPHardwardDataType);
  my %system_profiler;
  $system_profiler{uc $1} = $2
    while $system_profiler_output =~ m/^\s*([\w ]+):\s+(.+)$/gm;

  my $ncpus = $system_profiler{'NUMBER OF CPUS'};
  if (!defined $ncpus) {
    $ncpus = $system_profiler{'TOTAL NUMBER OF CORES'};
  }
  return $ncpus;
}

sub _getNumCpus_from_prtconf {    # NOT TESTED
  # solaris has a prtconf command, but I don't think it outputs #cpus.
  return 0 if $^O !~ /aix/i;
  return 0 if !_configExternalProgram("prtconf");
  my $cmd = _configExternalProgram("prtconf");
  my @result;
  @result = qx($cmd 2> /dev/null);
  my ($result) = grep { /Number Of Processors:/ } @result;
  return 0 if !$result;
  my ($ncpus) = $result =~ /:\s+(\d+)/;
  return $ncpus || 0;
}

sub _getNumCpus_from_Test_Smoke_SysInfo {   # NOT TESTED
  return 0 if !_configModule('Test::Smoke::SysInfo');
  my $sysinfo = Test::Smoke::SysInfo->new();
  if (defined $sysinfo && defined $sysinfo->{_ncpu}) {
    return $sysinfo->{_ncpu};
  }
  return;
}

######################################################################

# get affinity toolbox

sub _getAffinity_with_Win32API {
  my $opid = shift;
  return 0 if $^O ne "MSWin32" && $^O ne "cygwin";
  return 0 if !_configModule("Win32::API");

  my $pid = $opid;
  if ($^O eq "cygwin") {
    $pid = __pid_to_winpid($opid);
  }

  if ($pid > 0) {
    my ($processHandle, $processMask, $systemMask);
    ($processMask, $systemMask) = (0,0);

    # 0x0400 - PROCESS_QUERY_INFORMATION, 
    # 0x1000 - PROCESS_QUERY_LIMITED_INFORMATION
    return 0 unless $processHandle = _win32api("OpenProcess",0x0400,0,$pid)
                              || _win32api("OpenProcess",0x1000,0,$pid);
    return 0 unless _win32api("GetProcessAffinityMask", $processHandle,
			  $processMask, $systemMask);

    my $mask = 0;
    foreach my $char (split //, $processMask) {
      $mask <<= 8;
      $mask += ord($char);
    }
    _debug("affinity with Win32::API: $mask");
    return $mask;
  } else { # $pid is a Windows pseudo-process (thread ID)

    my ($threadHandle, $threadMask, $systemMask);
    ($threadMask, $systemMask) = (0,0);

    # 0x0020: THREAD_QUERY_INFORMATION
    # 0x0400: THREAD_QUERY_LIMITED_INFORMATION
    # 0x0040: THREAD_SET_INFORMATION
    # 0x0200: THREAD_SET_LIMITED_INFORMATION
    return 0 unless $threadHandle 
      = _win32api("OpenThread", 0x0060, 0, -$pid)
	|| _win32api("OpenThread", 0x0600, 0, -$pid)
	|| _win32api("OpenThread", 0x0020, 0, -$pid)
	|| _win32api("OpenThread", 0x0400, 0, -$pid);

    # there is no GetThreadAffinityMask function in Win32 API.
    # SetThreadAffinityMask will return the previous affinity,
    # but then you have to call it again to restore the correct value.
    # Also, SetThreadAffinityMask won't work if you don't have permission
    # to change the affinity.

    my $mask = 1;
    my $previous_affinity = _win32api("SetThreadAffinityMask", 
				      $threadHandle, $mask);
    if ($previous_affinity == 0) {
      carp "Win32::API::SetThreadAffinityMask: $! / $^E\n";
      return 0;
    }

    # hope we can restore it.
    if ($previous_affinity != $mask) {
      my $new_affinity = _win32api("SetThreadAffinityMask", 
				   $threadHandle, $previous_affinity);
      if ($new_affinity == 0) {
	carp "Sys::CpuAffinity::_getThreadAffinity_with_Win32API: ",
	  "set thread $pid affinity to $mask in order to retrieve ",
	  "affinity, but was unable to restore previous value: $! / $^E\n";
      }
    }
    return $previous_affinity;
  }
}

sub _getAffinity_with_Win32Process {
  my $pid = shift;

  return 0 if $^O ne "MSWin32" && $^O ne "cygwin";
  return 0 if !_configModule("Win32::Process");
  return 0 if $pid < 0;  # pseudo-process / thread id

  if ($^O eq "cygwin") {
    $pid = __pid_to_winpid($pid);
  }

  my ($processHandle, $processMask, $systemMask, $result);
  ($processMask, $systemMask) = (0,0);
  return 0 unless Win32::Process::Open($processHandle, $pid, 0) 
    && ref $processHandle eq 'Win32::Process';
  return 0 unless $processHandle->GetProcessAffinityMask(
				$processMask, $systemMask);
  _debug("affinity with Win32::Process: $processMask");
  return $processMask;
}

sub _getAffinity_with_taskset {
  my $pid = shift;
  return 0 if $^O ne "linux";
  return 0 if !_configExternalProgram("taskset");
  my $taskset = _configExternalProgram("taskset");
  my $taskset_output = qx($taskset -p $pid 2>/dev/null);
  $taskset_output =~ s/\s+$//;
  _debug("taskset output: $taskset_output");
  return 0 unless $taskset_output;
  my ($mask) = $taskset_output =~ /: (\S+)/;
  _debug("affinity with taskset: $mask");
  return hex($mask);
}

sub _getAffinity_with_xs_sched_getaffinity {
  my $pid = shift;
  return 0 if !defined &xs_sched_getaffinity_get_affinity;
  return xs_sched_getaffinity_get_affinity($pid);
}

sub _getAffinity_with_pbind {
  my ($pid) = @_;
  return 0 if $^O !~ /solaris/i;
  return 0 if !_configExternalProgram("pbind");
  my $pbind = _configExternalProgram("pbind");
  my $cmd = "$pbind -q $pid";
  my $pbind_output = qx($cmd 2>/dev/null);

  # possible output:
  #     process id $pid: $index
  #     process id $pid: not bound

  if ($pbind_output =~ /not bound/) {
    my $np = getNumCpus();
    if ($np > 0) {
      return (2 ** $np) - 1;
    } else {
      carp "_getAffinity_with_pbind: ",
	"process $pid unbound but can't count processors\n";
      return 2**32 - 1;
    }
  } elsif ($pbind_output =~ /: (\d+)/) {
    my $bound_processor = $1;
    return 1 << $bound_processor;
  }
  return 0;
}

sub _getAffinity_with_xs_processor_bind {
  my ($pid) = @_;
  return 0 if !defined &xs_getaffinity_processor_bind;
  my $mask = xs_getaffinity_processor_bind($pid);
  if ($mask == -10) {
    my $np = getNumCpus();
    if ($np > 0) {
      $mask = (2 ** $np) - 1;
      return $mask;
    } else {
      return 0;
    }
  }
  _debug("affinity with getaffinity_xs_processor_bind: $mask");
  return _arrayToMask($mask);
}

sub _getAffinity_with_BSD_Process_Affinity {
  my ($pid) = @_;
  return 0 if $^O !~ /bsd/i;
  return 0 if !_configModule("BSD::Process::Affinity");

  my $mask;
  eval {
      $mask = BSD::Process::Affinity
	  ->get_process_mask($pid)
	  ->to_bits()->to_Dec();
    BSD::Process::Affinity->get_process_mask($pid)->get_cpusetid();
  };
  if ($@) {
    _debug("error in _setAffinity_with_BSD_Process_Affinity: $@");
    # $MODULE{"BSD::Process::Affinity"} = 0
    return 0;
  }
  return $mask;
}

sub _getAffinity_with_cpuset {
    my ($pid) = @_;
    return 0 if $^O !~ /bsd/i;
    return 0 if !_configExternalProgram("cpuset");
    my $cpuset = _configExternalProgram("cpuset");
    my $cmd = "$cpuset -g -p $pid";
    my $cpuset_output = qx($cmd 2> /dev/null);

    # output format:
    #     pid nnnnn masK: i, j, k, ...

    $cpuset_output =~ s/.*:\s*//;
    my @cpus = split /\s*,\s*/, $cpuset_output;
    if (@cpus > 0) {
	return _arrayToMask(@cpus);
    }
    return 0;
}

sub _getAffinity_with_xs_cpuset_getaffinity {
  my ($pid) = @_;
  return 0 if !defined &xs_getaffinity_cpuset_get_affinity;
  return xs_getaffinity_cpuset_get_affinity($pid);
}

sub _getAffinity_with_xs_win32 {
  my ($opid) = @_;
  my $pid = $opid;
  if ($^O =~ /cygwin/) {
    $pid = __pid_to_winpid($opid);
  }
  if ($pid < 0) {
    return 0 if !defined &xs_win32_getAffinity_thread;
    return xs_win32_getAffinity_thread(-$pid);
  } elsif ($opid == $$) {
    if (defined &xs_win32_getAffinity_proc) {
      return xs_win32_getAffinity_proc($pid);
    } elsif (defined &xs_win32_getAffinity_thread) {
      return xs_win32_getAffinity_thread(0);
    }
    return 0;
  } elsif (defined &xs_win32_getAffinity_proc) {
    return xs_win32_getAffinity_proc($pid);
  }
  return 0;
}

######################################################################

# set affinity toolbox

sub _setAffinity_with_Win32API {
  my ($pid, $mask) = @_;
  return 0 if $^O ne "MSWin32" && $^O ne "cygwin";
  return 0 if !_configModule("Win32::API");

  # if $^O is "cygwin", make sure you are passing the Windows pid,
  # using Cygwin::pid_to_winpid if necessary!

  if ($^O eq "cygwin") {
    $pid = __pid_to_winpid($pid);
    if ($DEBUG) {
      print STDERR "winpid is $pid ($_[0])\n";
    }
  }

  if ($pid > 0) {
    my $processHandle;
    # 0x0200 - PROCESS_SET_INFORMATION
    $processHandle = _win32api("OpenProcess", 0x0200,0,$pid);
    if ($DEBUG) {
      print STDERR "process handle: $processHandle\n";
    }
    return 0 unless $processHandle;
    my $result = _win32api("SetProcessAffinityMask", $processHandle, $mask);
    _debug("set affinity with Win32::API: $result");
    return $result;
  } else {
    # negative pid indicates Windows "pseudo-process", which should
    # use the Thread functions.
    # Thread access rights definitions:
    # 0x0020: THREAD_QUERY_INFORMATION
    # 0x0400: THREAD_QUERY_LIMITED_INFORMATION
    # 0x0040: THREAD_SET_INFORMATION
    # 0x0200: THREAD_SET_LIMITED_INFORMATION
    my $threadHandle;
    local $! = undef;
    $^E = 0;
    return 0 unless $threadHandle
      = _win32api("OpenThread", 0x0060, 0, -$pid)
	|| _win32api("OpenThread", 0x0600, 0, -$pid)
	|| _win32api("OpenThread", 0x0040, 0, -$pid)
	|| _win32api("OpenThread", 0x0200, 0, -$pid);
    my $previous_affinity = _win32api("SetThreadAffinityMask",
				      $threadHandle, $mask);
    if ($previous_affinity == 0) {
      carp "Sys::CpuAffinity::_setAffinity_with_Win32API: ",
	"SetThreadAffinityMask call failed: $! / $^E\n";
    }
    return $previous_affinity;
  }
}

sub _setAffinity_with_Win32Process {
  my ($pid, $mask) = @_;
  return 0 if $^O ne "MSWin32";   # cygwin? can't get it to work reliably
  return 0 if !_configModule("Win32::Process");

  $DB::single = 1;

  if ($^O eq "cygwin") {
    $pid = __pid_to_winpid($pid);

    if ($DEBUG) {
      print STDERR "cygwin pid $_[0] => winpid $pid\n";
    }
  }

  my $processHandle;
  return 0 unless Win32::Process::Open($processHandle, $pid, 0)
    && ref $processHandle eq 'Win32::Process';

  # Seg fault on Cygwin? We really prefer not to use it on Cygwin.
  local $SIG{SEGV} = 'IGNORE';

  # SetProcessAffinityMask: "only available on Windows NT"
  use Config;
  my $v = $Config{osvers};
  if ($^O eq 'MSWin32' && ($v < 3.51 || $v >= 6.0)) {
    if ($DEBUG) {
      print STDERR "SetProcessAffinityMask ",
	"not available on MSWin32 osvers $v?\n";
    }
    return 0;
  }
  # Don't trust Strawberry Perl $Config{osvers}. Win32::GetOSVersion
  # is more reliable if it is available.
  if (_configModule('Win32')) {
    if (!Win32::IsWinNT()) {
      if ($DEBUG) {
	print STDERR "SetProcessorAffinityMask ",
	  "not available on MSWin32 OS Version $v\n";
      }
      return 0;
    }
  }

  my $result = $processHandle->SetProcessAffinityMask($mask);
  _debug("set affinity with Win32::Process: $result");
  return $result;
}

sub _setAffinity_with_taskset {
  my ($pid, $mask) = @_;
  return 0 if $^O ne "linux" || !_configExternalProgram("taskset");
  # my $n = sprintf '%x', $mask;
  my $cmd = sprintf('%s -p %x %d 2>&1', 
		    _configExternalProgram('taskset'), $mask, $pid);
  
  my $taskset_output = qx($cmd);
  my $taskset_status = $?;

  if ($taskset_status) {
      _debug("taskset output: $taskset_output");
  }

  return $taskset_status == 0;
}

sub _setAffinity_with_xs_sched_setaffinity {
  my ($pid,$mask) = @_;
  return 0 if !defined &xs_sched_setaffinity_set_affinity;
  return xs_sched_setaffinity_set_affinity($pid,$mask);
}

sub _setAffinity_with_BSD_Process_Affinity {
  my ($pid,$mask) = @_;
  return 0 if $^O !~ /bsd/i;
  return 0 if !_configModule("BSD::Process::Affinity");

  eval {
    BSD::Process::Affinity
	->get_process_mask($pid)
	->from_num($mask)
	->update();
  };
  if ($@) {
    _debug("error in _setAffinity_with_BSD_Process_Affinity: $@");
    return 0;
  }
}

sub _setAffinity_with_bindprocessor {
  my ($pid,$mask) = @_;
  return 0 if $^O !~ /aix/i;
  return 0 if !_configExternalProgram("bindprocessor");
  my $cmd = _configExternalProgram("bindprocessor");
  carp "not implemented for aix";
  return 0;
}

sub _setAffinity_with_xs_processor_bind {
  my ($pid,$mask) = @_;
  my $np = getNumCpus();
  if ($mask + 1 == 2 ** $np) {
    return 0 if !defined &xs_setaffinity_processor_unbind;
    my $result = xs_setaffinity_processor_unbind($pid);
    _debug("result from xs_setaffinity_processor_unbind: $result");
    return $result;
  } else {
    my @amask = _maskToArray($mask);
    return 0 if !defined &xs_setaffinity_processor_bind;

    # solaris processor_bind() is for binding to a single processor.
    # see comment under _setAffinity_with_pbind().

    my $element = 0;
    my $result = xs_setaffinity_processor_bind($pid,$amask[$element]);
    _debug("result from setaffinity_processor_bind: $result");
    return $result;
  }

}

sub _setAffinity_with_pbind {
  my ($pid,$mask) = @_;
  return 0 if $^O !~ /solaris/i;
  return 0 if !_configExternalProgram("pbind");
  my $pbind = _configExternalProgram("pbind");

  my @mask = _maskToArray($mask);

  # a limitation of pbind (maybe it is a limitation of solaris)
  # is that a process gets bound to ONE processor.
  # Do we want to bind to a random element of $mask?
  # Let's do the FIRST element for now.

  my $np = getNumCpus();
  my $c1;
  if ($np > 0 && $mask + 1 == 2 ** $np) {
      $c1 = system("'$pbind' -u $pid > /dev/null 2>&1");
  } else {
      my $element = 0;
      $c1 = system("'$pbind' -b $mask[$element] $pid > /dev/null 2>&1");
  }
  return !$c1;
}

# Don't use psrset command. Any processors used in a processor set
# may not be used by processes that are not assigned to the set.
#
#sub _setAffinity_with_psrset { # XXX - needs work
#  my ($pid,$mask) = @_;
#  return 0 if !_configExternalProgram("psrset");
#
#  # using  psrset  makes processors unavailable to any
#  # processes that were not assigned to the processor set?
#  # that seems pretty lame.
#
#  return 0;
#}

sub _setAffinity_with_cpuset {
    my ($pid, $mask) = @_;
    return 0 if $^O !~ /bsd/i; 
    return 0 if !_configExternalProgram("cpuset");

    my $lmask = join ",", _maskToArray($mask);
    my $cmd = _configExternalProgram("cpuset") . " -l $lmask -p $pid";
    my $c1 = system("$cmd 2>/dev/null");
    return !$c1;
}

sub _setAffinity_with_xs_cpuset_setaffinity {
  my ($pid,$mask) = @_;
  return 0 if !defined &xs_cpuset_set_affinity;
  return xs_cpuset_set_affinity($pid,$mask);
}

sub _setAffinity_with_xs_win32 {
  my ($opid, $mask) = @_;

$DB::single = 1;

  my $pid = $opid;
  if ($^O =~ /cygwin/) {
    $pid = __pid_to_winpid($opid);
  }

  if ($pid < 0) {
    if (defined &xs_win32_setAffinity_thread) {
      _debug("xs_win32_setAffinity_thread -\$pid");
      return xs_win32_setAffinity_thread(-$pid,$mask);
    }
    return 0;
  } elsif ($opid == $$) {

    if (0 && $^O ne 'cygwin' && defined &xs_win32_setAffinity_thread) {
      my $r = xs_win32_setAffinity_thread(0, $mask);
      return $r if $r;
    }
    if (defined &xs_win32_setAffinity_proc) {
      _debug("xs_win32_setAffinity_proc \$\$");
      return xs_win32_setAffinity_proc($pid,$mask);
    }
    if ($^O eq 'cygwin' && defined &xs_win32_setAffinity_thread) {
      my $r = xs_win32_setAffinity_thread(0, $mask);
      return $r if $r;
    }
    return 0;
  } elsif (defined &xs_win32_setAffinity_proc) {
    _debug("xs_win32_setAffinity_proc +\$pid");
    return xs_win32_setAffinity_proc($pid, $mask);
  }
  return 0;
}

sub __pid_to_winpid {
  my ($cygwinpid) = @_;
  if ($] >= 5.008 && defined(&Cygwin::pid_to_winpid)) {
    return Cygwin::pid_to_winpid($cygwinpid);
  } else {
    return __poor_mans_pid_to_winpid($cygwinpid);
  }
}

sub __poor_mans_pid_to_winpid {
  my ($cygwinpid) = @_;
  my @psw = `/usr/bin/ps -W`;
  foreach my $psw (@psw) {
    $psw =~ s/^[A-Z\s]+//;
    my ($pid,$ppid,$pgid,$winpid) = split /\s+/, $psw;
    next unless $pid;
    if ($pid == $cygwinpid) {
      return $winpid;
    }
  }
  warn "Could not resolve cygwin pid $cygwinpid into winpid.\n";
  return $cygwinpid;
}

######################################################################

# configuration code

sub _debug {
  return if !$DEBUG;
  print STDERR "Sys::CpuAffinity: ",@_,"\n";
}

our %MODULE = ();
our %PROGRAM = ();
our %INLINE_CODE = ();

sub _configModule {
  my $module = shift;
  return $MODULE{$module} if defined $MODULE{$module};
  eval "require $module";
  if ($@) {
    _debug("module $module not available: $@");
    return $MODULE{$module} = 0;
  } else {
    _debug("module $module is available.");
    return $MODULE{$module} = 1;
  }
}

our @PATH = ();
sub _configExternalProgram {
  my $program = shift;
  return $PROGRAM{$program} if defined $PROGRAM{$program};
  if (-x $program) {
    _debug("Program $program is available in $program");
    return $PROGRAM{$program} = $program;
  }

  if ($^O ne 'MSWin32') {
    my $which = qx(which $program 2>/dev/null);
    $which =~ s/\s+$//;

    if ($which =~ / not in / 			# negative output on irix
	|| $which =~ /no \Q$program\E in /	# negative output on solaris
	|| $which =~ /Command not found/        # negative output on openbsd
	|| ! -x $which                          # output is not executable, may be junk
       ) {

      $which = '';
    }
    if ($which) {
      _debug("Program $program is available in $which");
      return $PROGRAM{$program} = $which;
    }
  }

  # poor man's which
  if (@PATH == 0) {
    @PATH = split /:/, $ENV{PATH};
    push @PATH, split /;/, $ENV{PATH};
    push @PATH, ".";
    push @PATH, "/sbin", "/usr/sbin";
  }
  foreach my $dir (@PATH) {
    if (-x "$dir/$program") {
      _debug("Program $program is available in $dir/$program");
      return $PROGRAM{$program} = "$dir/$program";
    }
  }
  return $PROGRAM{$program} = 0;
}

######################################################################

# some Win32::API specific code

our %WIN32_API_SPECS
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

sub _win32api {
  my $function = shift;
  return if !_configModule("Win32::API");
  if (!defined $WIN32API{$function}) {
    my $spec = $WIN32_API_SPECS{$function};
    if (!defined $spec) {
      croak "Sys::CpuAffinity: bad Win32::API function request: $function\n";
    }

    local $! = undef;
    $WIN32API{$function} = Win32::API->new(@$spec);
    # _debug("Win32::API function $function: ", $WIN32API{$function});
    if ($!) {
      # carp "Sys::CpuAffinity: ",
      #	  "error initializing Win32::API function $function: $! / $^E\n";
      $WIN32API{$function} = 0;
      return;
    }
  }
  return if !defined($WIN32API{$function}) || $WIN32API{$function} == 0;
  return $WIN32API{$function}->Call(@_);
}

######################################################################

1; # End of Sys::CpuAffinity

__END__

######################################################################

=head1 NAME

Sys::CpuAffinity - Set CPU affinity for processes

=head1 VERSION

Version 0.99

=head1 SYNOPSIS

    use Sys::CpuAffinity;

    $num_cpus = Sys::CpuAffinity::getNumCpus();

    $mask = 1 | 4 | 8 | 16;   # prefer CPU's # 0, 2, 3, 4
    $success = Sys::CpuAffinity::setAffinity($pid,$mask);
    $success = Sys::CpuAffinity::setAffinity($pid, \@preferred_cpus);

    $mask = Sys::CpuAffinity::getAffinity($pid);
    @cpus = Sys::CpuAffinity::getAffinity($pid);

=head1 DESCRIPTION

The details of getting and setting process CPU affinities
varies greatly from system to system. Even among the different
flavors of Unix there is very little in the way of a common
interface to CPU affinities. The existing tools and libraries
for setting CPU affinities are not very standardized, so
that a technique for setting CPU affinities on one system
may not work on another system with the same architecture.

This module seeks to do one thing and do it well:
manipulate CPU affinities through a common interface
on as many systems as possible, by any means necessary.

The module is composed of several subroutines, each one 
implementing a different technique to perform a CPU affinity
operation. A technique might try to import a Perl module,
run an external program that might be installed on your system,
or invoke some C code to access your system libraries.
Usually, a technique is applicable to only a single
or small group of operating systems, and on any particular 
system, the vast majority of techniques would fail. 
Regardless of your particular system and configuration,
it is hoped that at least one of the techniques will work
and you will be able to get and set the CPU affinities of
your processes.

=head1 RECOMMENDED MODULES

No modules are required by Sys::CpuAffinity, but there are
several techniques for manipulating CPU affinities in
other existing modules, and Sys::CpuAffinity will use
these modules if they are available:

    Win32::API, Win32::Process [MSWin32, cygwin]
    BSD::Process::Affinity [FreeBSD, NetBSD]

=head1 SUPPORTED SYSTEMS

The techniques for manipulating CPU affinities for Windows
(including Cygwin) and Linux have been refined and tested
pretty well. Some techniques applicable to BSD systems
(particularly FreeBSD) and Solaris have been tested a little bit. 
The hope is that this module will include more techniques for
more systems in future releases. See the L</"NOTE TO DEVELOPERS">
below for information about how you can help.

MacOS is explicitly not supported, as there does not appear to
be any public interface for specifying the CPU affinity of
a process directly.

=head1 SUBROUTINES/METHODS

=over 4

=item C<$bitmask = Sys::CpuAffinity::getAffinity($pid)>

=item C<@preferred_cpus = Sys::CpuAffinity::getAffinity($pid)>

Retrieves the current CPU affinity for the process
with the specified process ID.
In scalar context, returns a bit-vector of the CPUs that the
process has affinity for, with the least significant bit
denoting CPU #0.

In array context, returns a list of integers indicating the
indices of the CPU that the process has affinity for.

So for example, if a process in an 8-CPU machine
had affinity for CPU's # 2, 6, and 7, then
in scalar context, C<getAffinity()> would return

    (1 << 2) | (1 << 6) | (1 << 7) ==> 196

and in array context, it would return

    (2, 6, 7)

The function may return 0 or C<undef> in case of an error
such as an invalid process ID.

=back

=over 4

=item C<$success = Sys::CpuAffinity::setAffinity($pid, $bitmask)>

=item C<$success = Sys::CpuAffinity::setAffinity($pid, \@preferred_cpus)>

Sets the CPU affinity of a process to the specified processors.
First argument is the process ID. The second argument is either
a bitmask of the desired procesors to assign to the PID, or an
array reference with the index values of processors to assign to
the PID.

    # two ways to assign to CPU #'s 1 and 4:
    Sys::CpuAffinity::setAffinity($pid, 0x12); # 0x12 = (1<<1) | (1<<4)
    Sys::CpuAffinity::setAffinity($pid, [1,4]);

As a special case, using a C<$bitmask> value of C<-1> will clear
the CPU affinities of a process -- setting the affinity to all
available processors.

=back

=over 4

=item C<$ncpu = Sys::CpuAffinity::getNumCpus()>

Returns the module's best guess about the number of 
processors on this system.

=back

=head1 AUTHOR

Marty O'Brien, C<< <mob at cpan.org> >>

=head1 BUGS AND LIMITATIONS

This module may not work or produce undefined results on
systems with more than 32 CPUs.

Please report any bugs or feature requests to 
C<bug-sys-cpuaffinity at rt.cpan.org>, or through
the web interface at 
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Sys-CpuAffinity>.  
I will be notified, and then you'll automatically be notified of 
progress on your bug as I make changes. 

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Sys::CpuAffinity

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sys-CpuAffinity>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Sys-CpuAffinity>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Sys-CpuAffinity>

=item * Search CPAN

L<http://search.cpan.org/dist/Sys-CpuAffinity/>

=back

=head1 NOTE TO DEVELOPERS

This module seeks to work for as many systems in as many
configurations as possible. If you know of a tool, a function,
a technique to set CPU affinities on a system -- any system,
-- then let's include it in this module. 

Feel free to submit code through this module's request tracker:

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Sys-CpuAffinity>

or directly to me at C<< <mob at cpan.org> >> and it will
be included in the next release.

=head1 ACKNOWLEDGEMENTS

L<BSD::Process::Affinity> for demonstrating how to get/set affinities
on BSD systems.

L<Test::Smoke::SysInfo> has some fairly portable code for detecting
the number of processors.

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Marty O'Brien.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut








######################################################################

Notes and to do list:

Why worry about CPU affinity? See 
http://www.ibm.com/developerworks/linux/library/l-affinity.html?ca=dgr-lnxw41Affinity
Other reasons are:
    bind expensive processes to subset of CPUs, leaving at least
    one CPU for other tasks or other users

See http://www.ibm.com/developerworks/aix/library/au-processinfinity.html
for hints about cpu affinity on AIX

From v0.90, test to get num CPUs failed on Irix.

Rumors of cpu affinity on other systems:
    BSD:  pthread_setaffinity_np(), pthread_getaffinity_np()
          copy XS code from BSD::Resource::Affinity
          FreeBSD:  /cpuset, cpuset_setaffinity(), cpuset_getaffinity()
          NetBSD:   /psrset
    Irix: /dplace, cpusetXXX() methods (with -lcpuset)
    Solaris:  /pbind, /psrset, processor_bind(), pset_bind()
    From //developers.sun.com/solaris/articles/solaris_processor.html

          It is not easy to allocate more than one CPU to a multithreaded
          application since this would have to be done programmatically
          using processor_bind().

          /psrset returns a unique ID that is bound to a specific
          set of processors. 

          A process that has been affined with /psrset cannot be reaffined
          with /pbind

          It is not possible to bind every CPU to a user processor set.
          At least one CPU needs to remain unbound since otherwise the
          kernel itself would not have any CPU left for its own processing
          [huh? so psrset prevents the kernel from using some processors?]

    Solaris:  Solaris::Lgrp module 
	lgrp_affinity_set(P_PID,$pid,$lgrp,LGRP_AFF_xxx)
        lgrp_affinity_get(P_PID,$pid,$lgrp)
        affinity_get

    AIX:  /bindprocessor, bindprocessor() in <sys/processor.h>
    MacOS: thread_policy_set(),thread_policy_get() in <mach/thread_policy.h>

	In MacOS it is possible to assign threads to the same
	processor, but generally not to assign them to any particular
	processor. MacOS is totally unsupported for now.


how to find the number of processors:
    AIX:  sysconf(_SC_NPROCESSORS_CONF), sysconf(_SC_NPROCESSORS_ONLN)
          prtconf | grep "Number Of Processors:" | cut -d: -f2
    Solaris:   processor_info(), p_online()
    MacOS:     hwprefs cpu_count, system_profiler | grep Cores: | cut -d: -f2
               do something with `sysctl -a`
    AIX:       prtconf
               solaris also has prtconf, but don't think it has cpu data
    BSD also has `sysctl`, they tell me
        AIX:   `smtctl | grep "Bind processor "`  ... not reliable
        AIX has /proc/cpuinfo available, too (or so I've heard)
        AIX:   `lsdev -Cc processor`
        AIX:    `bindprocessor -q`


Some systems have a concept of "processor groups" or "cpu sets"
that can we could either exploit or be exploited by

Some systems have a concept of "strong" affinity and "weak" affinity.
Where the distinction is important, let's use "strong" affinity
by default.

Some systems have a concept of the maximum number of processors that
they can suppport.

Currently (0.91-0.99), constant parameters to Win32 API functions are 
hard coded, not extracted from the local header files. Microsoft is
probably loathe to change these constants between different versions,
but this still seems dodgy.


##########################################

Cygwin: if Win32::API is not installed and setCpuAffinity doesn't work,
recommend Win32::API

OpenBSD doesn't have a way to set affinity (yet?) ? What about using
the data structures under sys/proc.h? Now that I have a devio.us account
I can check it out.


