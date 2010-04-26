#
# Forks::Super::Job::OS
# implementation of
#     fork { name => ... , os_priority => ... ,
#            cpu_affinity => 0x... }
#

package Forks::Super::Job::OS;
use Forks::Super::Config ':all';
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(isValidPid);
use Carp;
use strict;
use warnings;

$Carp::Internal{ (__PACKAGE__) }++;
our $VERSION = $Forks::Super::Debug::VERSION;

{
  require Forks::Super::Job::OS::Win32 if $^O eq 'MSWin32' || $^O =~ /cygwin/i;
}

our $CPU_AFFINITY_CALLS = 0;
our $OS_PRIORITY_CALLS = 0;

sub preconfig_os {
  my $job = shift;
  if (defined $job->{cpu_affinity}) {
    $job->{cpu_affinity_call} = ++$CPU_AFFINITY_CALLS;
  }
  if (defined $job->{os_priority}) {
    $job->{os_priority_call} = ++$OS_PRIORITY_CALLS;
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

  $ENV{_FORK_PPID} = $$ if $^O eq 'MSWin32';
  if (defined $job->{os_priority}) {
    set_os_priority($job);
  }

  if (defined $job->{cpu_affinity}) {
    validate_cpu_affinity($job) && set_cpu_affinity($job);
  }
  return;
}

sub set_os_priority {
  my ($job) = @_;
  my $priority = $job->{os_priority} || 0;
  my $q = -999;

  local $@ = undef;
  my $z = eval {
    setpriority(0,0,$priority);
  };
  return 1 unless $@;

  if ($^O eq 'MSWin32') {
    if (!CONFIG('Win32::API')) {
      if ($job->{os_priority_call} == 1) {
	carp "Forks::Super::Job::config_os_child(): ",
	  "cannot set child process priority on MSWin32.\n",
	  "Install the Win32::API module to enable this feature.\n";
      }
      return;
    }

    require Forks::Super::Job::OS::Win32;
    return Forks::Super::Job::OS::Win32::set_os_priority($job, $priority);
  }

  if ($job->{os_priority_call} == 1) {
    carp "Forks::Super::Job::config_os_child(): ",
      "failed to set child process priority on $^O\n";
  }
  return;
}

sub set_cpu_affinity {
  my ($job) = @_;
  my $n = $job->{cpu_affinity};

  if ($n == 0) {
    carp "Forks::Super::Job::config_os_child(): ",
      "desired cpu affinity set to zero. Is that what you really want?\n";
  }

  if (CONFIG('Sys::CpuAffinity')) {
    return Sys::CpuAffinity::setAffinity($$, $n);
  } elsif ($job->{cpu_affinity_call} == 1) {
    carp_once "Forks::Super::config_os_child(): ",
      "cannot set child process's cpu affinity.\n",
      "Install the Sys::CpuAffinity module to enable this feature.\n";
  }
}

sub validate_cpu_affinity {
  my $job = shift;
  my $bitmask = $job->{cpu_affinity};
  my $np = get_number_of_processors();
  $np = '' if $np <= 0;
  if ($np > 0 && $bitmask >= (2 ** $np)) {
    $job->{_cpu_affinity} = $bitmask;
    $bitmask &= (2 ** $np) - 1;
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

sub get_cpu_load {
  if (CONFIG('Sys::CpuLoadX')) {
    my $load = Sys::CpuLoadX::get_cpu_load();
    if ($load >= 0.0) {
      return $load;
    } else {
      carp_once "Forks::Super::Job::OS::get_cpu_load: ",
	"Sys::CpuLoadX module is installed but still ",
	  "unable to get current CPU load for $^O $].";
      return -1.0;
    }
  } else { # pray for `uptime`.
    my $uptime = `uptime 2>/dev/null`;
    $uptime =~ s/\s+$//;
    my @uptime = split /[\s,]+/, $uptime;
    if (@uptime > 2) {
      if ($uptime[-3] =~ /\d/ && $uptime[-3] >= 0.0) {
	return $uptime[-3];
      }
    }
  }

  my $install = "Install the Sys::CpuLoadX module";
  carp_once "Forks::Super: max_load feature not available.\n",
    "$install to enable this feature.\n";
  return -1.0;
}

sub get_number_of_processors {
  return _get_number_of_processors_from_Sys_CpuAffinity()
    || _get_number_of_processors_from_proc_cpuinfo()
    || _get_number_of_processors_from_psrinfo()
    || _get_number_of_processors_from_ENV()
    || do {
      my $install = "Install the Sys::CpuAffinity module";
      carp_once "Forks::Super::get_number_of_processors(): ",
	"feature unavailable.\n",
	"$install to enable this feature.\n";
      -1
      };
}

sub _get_number_of_processors_from_Sys_CpuAffinity {
  if (CONFIG('Sys::CpuAffinity')) {
    return Sys::CpuAffinity::getNumCpus();
  }
  return 0;
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

sub _get_number_of_processors_from_psrinfo {
  # it's rumored that  psrinfo -v  on solaris reports number of cpus
  if (CONFIG('/psrinfo')) {
    my $cmd = CONFIG('/psrinfo') . ' -v';
    my @psrinfo = `$cmd 2>/dev/null`;
    my $num_processors = grep { /Status of processor \d+/ } @psrinfo;
    return $num_processors;
  }
  return;
}

sub _get_number_of_processors_from_ENV {
  # sometimes set in Windows, can be spoofed
  if ($ENV{NUMBER_OF_PROCESSORS}) {
    return $ENV{NUMBER_OF_PROCESSORS};
  }
  return 0;
}

sub _get_number_of_processors_from_dmesg {
  if (CONFIG('/dmesg')) {
    my $cmd = CONFIG('/dmesg') . ' | grep -i cpu';
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

sub kill_Win32_process_tree {
  my (@pids) = @_;
  my $count = 0;
  foreach my $pid (@pids) {
    next if !defined $pid || $pid == 0;

    # How many ways are there to kill a process in Windows?
    # How many do you need?

    my $c1 = () = grep { /ERROR/ } `TASKKILL /PID $pid /F /T 2>&1`;
    $c1 = system("TSKILL $pid /A > nul") if $c1;
    if ($c1 && CONFIG('Win32::Process::Kill')) {
      $c1 = !Win32::Process::Kill::Kill($pid);
    }

    if ($c1) {
      my $c2 = () = `TASKLIST /FI \"pid eq $pid\" 2> nul`;
      if ($c2 == 0) {
	warn "Forks::Super::Job::OS::kill_Win32_process_tree: ",
	  "$pid: no such process?\n";
      }
    }
    $count += !$c1;
  }
  return $count;
}

1;

__END__

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
