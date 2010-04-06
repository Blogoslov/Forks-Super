#
# Forks::Super::Job::OS
# implementation of
#     fork { name => ... , os_priority => ... ,
#            cpu_affinity => 0x... }
#

package Forks::Super::Job::OS;
use Forks::Super::Config ':all';
use Forks::Super::Debug qw(:all);
use Carp;
use strict;
use warnings;

$Carp::Internal{ (__PACKAGE__) }++;
our $VERSION = $Forks::Super::Debug::VERSION;

{
  *set_os_priority = *set_os_priority_generic;
  *set_cpu_affinity = *set_cpu_affinity_generic;
  *get_cpu_load = *get_cpu_load_generic;
  *get_free_memory = *get_free_memory_generic;
  *get_number_of_processors = *get_number_of_processors_generic;

  # starting with Windows and Cygwin
  # as we discover idiosyncracies and robust ways to perform
  # OS tasks in each system, we'll build out OS-specific
  # packages

  require Forks::Super::Job::OS::Win32 if $^O eq "MSWin32" || $^O eq "cygwin";
  *set_os_priority = *set_os_priority_generic if $^O eq 'cygwin';

  if ($^O =~ /linux/) { #  && CONFIG("Inline",0,"C")) {
    require Forks::Super::Job::OS::Linux;
  }
}





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
    set_os_priority($job);
  }

  if (defined $job->{cpu_affinity}) {
    validate_cpu_affinity($job) && set_cpu_affinity($job);
  }
  return;
}

sub validate_cpu_affinity {
  my $job = shift;
  my $bitmask = $job->{cpu_affinity};
  my $np = get_number_of_processors();
  $np = '' if $np <= 0;

  if ($np > 0 && $bitmask >= (1 << $np)) {
    $job->{_cpu_affinity} = $bitmask;
    $bitmask &= (1 << $np) - 1;
    $job->{cpu_affinity} = $bitmask;
  }
  if ($bitmask <= 0) {
    carp "Forks::Super::Job::config_os_child: ",
      "desired cpu affinity $bitmask does not specify any of the ",
      "valid $np processors that seem to be available on your system.\n";
    return 0;
  }
  return 1;
}

sub set_os_priority_generic {
  my ($job) = @_;
  my $p = $job->{os_priority} + 0;
  my $q = -999;

  if (0 && $^O eq "MSWin32" && CONFIG("Win32::API")) {
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
	  return $p || "0E0";
	} else {
	  carp "Forks::Super::Job::config_os_child(): ",
	    "setpriority() call failed $p ==> $q\n";
	  return 0;
	}
      }
      return 0;
    }
  } else {
    my $q;
    my $z = eval {
      setpriority(0,0,$p); 
      $q = getpriority(0,0);
    };
    if ($@) {
      carp "Forks::Super::Job::config_os_child(): ",
	"setpriority() call failed $p ==> $q\n";
      return 0;
    }
    return $q || "0E0";
  }
}

sub set_cpu_affinity_generic {
  my $job = shift;
  my $n = $job->{cpu_affinity};

  # XXX - I am working on a Sys::CpuAffinity module to handle
  # CPU affinity tasks. When an initial release is ready, I'll
  # just include it with this distribution

  if ($n == 0) {
    carp "Forks::Super::Job::config_os_child(): ",
      "desired cpu affinity set to zero. Is that what you really want?\n";
  }

  if (0 && $^O =~ /cygwin/i && CONFIG("Win32::Process")) {
  } elsif ($^O=~/linux/i && CONFIG("/taskset")) {
    $n = sprintf "0%o", $n;
    system(CONFIG("/taskset"),"-p",$n,$$);
  } elsif (0 && $^O eq "MSWin32" && CONFIG("Win32::API")) {
  } elsif (CONFIG('BSD::Process::Affinity')) {
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

  # See http://www.ibm.com/developerworks/aix/library/au-processinfinity.html
  # for hints about how to do this on AIX.

  # Rumors of cpu affinity on other systems:
  #    BSD:  pthread_setaffinity_np(), pthread_getaffinity_np()
  #          copy XS code from BSD::Resource::Affinity
  #          FreeBSD:  /cpuset
  #          NetBSD:   /psrset
  #    Irix: /dplace
  #    Solaris:  /pbind, /psrset, processor_bind(), pset_bind()
  #    AIX:  /bindprocessor, bindprocessor() in <sys/processor.h>
  #    MacOS: thread_policy_set(),thread_policy_get() in <mach/thread_policy.h>
  # 
}

sub _get_cpu_load_from_Sys_CpuLoad {
  if (CONFIG("Sys::CpuLoad")) {
    # this will probably only work on BSD systems
    my @z = Sys::CpuLoad::load();
    if (@z == 0) {
      return;
    }
    return $z[0] == 0.0 ? "0.00" : $z[0];  # 0.00 is zero but true
  }
  return 0;
}

sub _get_cpu_load_from_uptime {
  if (CONFIG("/uptime")) {
    my $uptime = CONFIG("/uptime");
    my $uptime_output = `$uptime 2>/dev/null`;
    if ($uptime_output) {
      $uptime = (split /\s+/, $uptime_output)[-3];
      $uptime =~ s/,//g;
      return $uptime;
    }
  }
  return 0;
}

sub get_cpu_load_generic {
  return
    _get_cpu_load_from_Sys_CpuLoad() ||
    _get_cpu_load_from_uptime() ||
    -1.0;
}

sub _get_number_of_processors_from_proc_cpuinfo {
  if (-r '/proc/cpuinfo') {
    my $num_processors = 0;
    my $procfh;
    if (open my $procfh, '<', '/proc/cpuinfo') {
      while (<$procfh>) {
	if (/^processor\s/) {
	  $num_processors++;
	}
      }
      close $procfh;
    }
    return $num_processors;
  }
  return;
}

sub _get_number_of_processors_from_mpstat {

  #
  # mpstat | tail +2 | wc -l  is not quite right
  # and it is really wrong in Linux where default mpstat is
  # a 2-line consolidated output and tail +2 doesn't work :-(
  #
  return 0;

  if (CONFIG("/mpstat")) {
    my $cmd = CONFIG("/mpstat") . ' 2>/dev/null | tail +2 | wc -l';
    my $num_processors = qx($cmd);

    $num_processors = 0;

    return $num_processors + 0;
  }
  return;
}

sub _get_number_of_processors_from_psrinfo {
  # it's rumored that  psrinfo -v  on solaris reports number of cpus
  if (CONFIG("/psrinfo")) {
    my $cmd = CONFIG("/psrinfo") . " -v";
    my @psrinfo = `$cmd 2>/dev/null`;
    my $num_processors = grep { /Status of processor \d+/ } @psrinfo;
    return $num_processors;
  }
  return;
}

sub _get_number_of_processors_from_dmesg {
  if (CONFIG("/dmesg")) {
    my $cmd = CONFIG("/dmesg") . " | grep -i cpu";
    my @dmesg = qw($cmd);

    # Looking at Linux 2.6.18-128.7.1.el5 x86_64 x86_64 x86_64 GNU/Linux,
    # there are many ways to get this out:

    my ($brought) = grep { /Brought up \d+ CPUs/i } @dmesg;
    if ($brought && $brought =~ /Brought up (\d+) CPUs/i) {
      return $1;
    }

    my @initializing = grep { /Initializing CPU\#\d+/ } @dmesg;
    if (@initializing > 0) {
      return scalar @initializing;
    }

    my @cpu_num = grep { /^cpu\#?\d+:/i } @dmesg;
    if (@cpu_num > 0) {
      my %cpu_num = map {/^cpu\#?(\d+):/;$1=>1} @cpu_num;
      if (0 < keys %cpu_num) {
	return scalar keys %cpu_num;
      }
    }
  }
  return;
}

sub get_number_of_processors_generic {
  return _get_number_of_processors_from_proc_cpuinfo()
    || _get_number_of_processors_from_mpstat()
    || _get_number_of_processors_from_psrinfo()
    || -1;

  # Rumors of how to do this on other systems:
  #      macos/darwin:  `hwprefs cpu_count`
  #                     `system_profiler | grep Cores: | cut -d: -f2`
  #                     do something with `sysctl -a`
  #      BSD also has `sysctl`, they tell me
  #      BSD:   `dmesg | grep -i cpu`
  #      Some systems?: `prtconf -v | head`, 
  #                     `prtconf | grep Processor | cut -d: -f2``
  #      AIX:   `smtctl | grep "Bind processor "`
  #      AIX has /proc/cpuinfo available, too (or so I've heard)
  #      AIX:   `lsdev -Cc processor`
  #      AIX:    `bindprocessor -q`
}

sub get_free_memory_generic {
  return 1.0;
}

1;

__END__

    my $p = $job->{os_priority} + 0;
    my $q = -999;

    if ($^O eq "MSWin32" && CONFIG("Win32::API")) {
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



$^O values to target, from perlport:

aix           
bsdos
darwin
dgux
dynixptx 
freebsd-i386
linux 
hpux 
irix 
darwin 
machten 
next 
openbsd 
dec_osf 
svr4 
sco_sv 
svr4 
unicos 
unicosmk 
unicos 
solaris 
sunos 
dos
os2
MSWin32
cygwin
MacOS
VMS
VOS
os390
os400
posix-bc
vmesa
riscos
amigaos
beos
mpeix

Not from perlport:
netbsd
midnightbsd
dragonfly

