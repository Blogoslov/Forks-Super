#
# Forks::Super::Job::OS
# implementation of
#     fork { name => ... , os_priority => ... ,
#            cpu_affinity => 0x... }
#

package Forks::Super::Job::OS;
use Forks::Super::Config ':all';
use Forks::Super::Debug qw(:all);
use Forks::Super::Util qw(isValidPid IS_WIN32 IS_CYGWIN);
use Carp;
use strict;
use warnings;
require Forks::Super::Job::OS::Win32 if &IS_WIN32 || &IS_CYGWIN;

our $VERSION = '0.55';

our $CPU_AFFINITY_CALLS = 0;
our $OS_PRIORITY_CALLS = 0;

sub _preconfig_os {
    my $job = shift;
    if (defined $job->{cpu_affinity}) {
	$job->{cpu_affinity_call} = ++$CPU_AFFINITY_CALLS;
    }
    if (defined $job->{os_priority}) {
	$job->{os_priority_call} = ++$OS_PRIORITY_CALLS;
    }
    return;
}

#
# If desired and if the platform supports it, set
# job-specific operating system settings like
# process priority and CPU affinity.
# Should only be run from a child process
# immediately after the fork.
#
sub Forks::Super::Job::_config_os_child {
    my $job = shift;

    if (defined $job->{name}) {
	$0 = $job->{name}; # might affect ps(1) output
    } else {
	$job->{name} = $$;
    }

    if (defined $job->{umask}) {
	umask $job->{umask};
    }

    if (&IS_WIN32) {
	$ENV{_FORK_PPID} = $$;
    }
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

    local $@ = undef;
    my $z = eval {
	setpriority(0,0,$priority);
    };
    return 1 if !$@;

    if (&IS_WIN32) {
	if (!CONFIG('Win32::API')) {
	    if ($job->{os_priority_call} == 1) {
		carp 'Forks::Super::Job::_config_os_child(): ',
		    "cannot set child process priority on MSWin32.\n",
		    "Install the Win32::API module to enable this feature.\n";
	    }
	    return;
	}

	require Forks::Super::Job::OS::Win32;
	return Forks::Super::Job::OS::Win32::set_os_priority($job, $priority);
    }

    if ($job->{os_priority_call} == 1) {
	carp 'Forks::Super::Job::_config_os_child(): ',
	    "failed to set child process priority on $^O\n";
    }
    return;
}

sub set_cpu_affinity {
    my ($job) = @_;
    my $n = $job->{cpu_affinity};

    if ($n == 0 || (ref($n) eq 'ARRAY' && @$n==0)) {
	carp 'Forks::Super::Job::_config_os_child(): ',
	    "desired cpu affinity set to zero. Is that what you really want?\n";
    }

    if (CONFIG('Sys::CpuAffinity')) {
	return Sys::CpuAffinity::setAffinity($$, $n);
    } elsif ($job->{cpu_affinity_call} == 1) {
	carp_once 'Forks::Super::_config_os_child(): ',
	    "cannot set child process's cpu affinity.\n",
	    "Install the Sys::CpuAffinity module to enable this feature.\n";
    }
    return;
}

sub validate_cpu_affinity {
    my $job = shift;
    $job->{_cpu_affinity} = $job->{cpu_affinity};
    my $np = get_number_of_processors();
    if ($np <= 0) {
	$np = 0;
    }
    if (ref($job->{cpu_affinity}) eq 'ARRAY') {
	my @cpu_list = grep { $_ >= 0 && $_ < $np } @{$job->{cpu_affinity}};
	if (@cpu_list == 0) {
	    carp 'Forks::Super::Job::_config_os_child: ',
	        "desired cpu affinity [ @{$job->{cpu_affinity}} ] ",
	        "does not specify any of the valid $np processors ",
	        "available on your system.\n";
	    return 0;
	}
	if (@cpu_list < @{$job->{cpu_affinity}}) {
	    $job->{cpu_affinity} = [ @cpu_list ];
	}
    } else {
	if ($np > 0 && $job->{cpu_affinity} >= (2 ** $np)) {
	    $job->{cpu_affinity} &= (2 ** $np) - 1;
	}
	if ($job->{cpu_affinity} <= 0) {
	    carp 'Forks::Super::Job::_config_os_child: ',
	        "desired cpu affinity $job->{_cpu_affinity} does ",
	        "not specify any of the valid $np processors that ",
	        "seem to be available on your system.\n";
	    return 0;
	}
    }
    return 1;
}

sub get_cpu_load {
    if (CONFIG('Sys::CpuLoadX')) {
	my $load = Sys::CpuLoadX::get_cpu_load();
	if ($load >= 0.0) {
	    return $load;
	} else {
	    carp_once 'Forks::Super::Job::OS::get_cpu_load: ',
	        'Sys::CpuLoadX module is installed but still ',
	        "unable to get current CPU load for $^O $].";
	    return -1.0;
	}
    } else { # pray for `uptime`.
	my $uptime = qx(uptime 2>/dev/null);        ## no critic (Backtick)
	$uptime =~ s/\s+$//;
	my @uptime = split /[\s,]+/, $uptime;
	if (@uptime > 2) {
	    if ($uptime[-3] =~ /\d/ && $uptime[-3] >= 0.0) {
		return $uptime[-3];
	    }
	}
    }

    my $install = 'Install the Sys::CpuLoadX module';
    carp_once "Forks::Super: max_load feature not available.\n",
        "$install to enable this feature.\n";
    return -1.0;
}

sub get_number_of_processors {
    return _get_number_of_processors_from_Sys_CpuAffinity()
	|| _get_number_of_processors_from_proc_cpuinfo()
	|| _get_number_of_processors_from_psrinfo()
	|| _get_number_of_processors_from_ENV()
	|| $Forks::Super::SysInfo::NUM_PROCESSORS
	|| do {
	    my $install = 'Install the Sys::CpuAffinity module';
	    carp_once 'Forks::Super::get_number_of_processors(): ',
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
	my @psrinfo = qx($cmd 2>/dev/null);     ## no critic (Backtick)
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
	    my %cpu_num = map {
		/^cpu\#?(\d+):/ ? ($1 => 1) : ();
	    } @cpu_num;
	    if (0 < keys %cpu_num) {
		return scalar keys %cpu_num;
	    }
	}
    }
    return;
}

# impose a timeout on a process from a separate small process.
# Usually, this is not the best way to get a process to shutdown
# after a timeout. Starting and stopping a new process has a lot
# of overhead for the operating system. It uses up a precious
# space in the process table. It terminates the process without
# prejudice, not allowing the process to clean itself up or
# otherwise trap a signal.
#
# But sometimes it is the only way if
#   * alarm() is not implemented on your system
#   * alarm() and sleep() are not compatible on your system
#   * you want to timeout a process that you will start with exec()
#
sub poor_mans_alarm {
    my ($pid, $timeout) = @_;

    if ($pid < 0) {
	# don't want to run in a separate process to kill a thread.
	if (CORE::fork() == 0) {
	    $0 = "PMA[2]($pid,$timeout)";
	    sleep 1, kill(0,$pid) || exit for 1..$timeout;
	    kill -9, $pid;
	    exit;
	}
    }

    # program to monitor a pid:
    my $prog = "\$0='PMA($pid,$timeout)';sleep 1,kill(0,$pid)||exit for 1..$timeout;kill -9,$pid";
    if (&IS_WIN32) {
	return system 1, qq[$^X -e "$prog"];
    } else {
	my $pm_pid = CORE::fork();
	if (!defined $pm_pid) {
	    carp 'FSJ::OS::poor_mans_alarm: fork to monitor process failed';
	    return;
	}
	if ($pm_pid == 0) {
	    exec($^X, '-e', $prog);
	}
	return $pm_pid;
    }
}

=begin XXXXXX removed 0.55 NOT USED

sub kill_Win32_process_tree {
    my (@pids) = @_;
    my $count = 0;
    foreach my $pid (@pids) {
	next if !defined($pid) || $pid == 0;

	# How many ways are there to kill a process in Windows?
	# How many do you need?

	my $c1 = () = grep { /ERROR/ } qx(TASKKILL /PID $pid /F /T 2>&1);
	if ($c1) {
	    $c1 = system("TASKILL $pid /A > nul");
	}
	if ($c1 && CONFIG('Win32::Process::Kill')) {
	    $c1 = !Win32::Process::Kill::Kill($pid);
	}

	if ($c1) {
	    my $c2 = () = qx(TASKLIST /FI \"pid eq $pid\" 2> nul);
	    if ($c2 == 0) {
		warn 'Forks::Super::Job::OS::kill_Win32_process_tree: ',
		"$pid: no such process?\n";
	    }
	}
	$count += !$c1;
    }
    return $count;
}

=end XXXXXX

=cut

1;

__END__
