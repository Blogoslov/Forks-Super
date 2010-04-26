use Sys::CpuAffinity;
use Test::More tests => 1;
use strict;
use warnings;

# output the relevant configuration of this system.
# when test t/10-exercise.t doesn't pass,
# this information is helpful in discovering why

print STDERR "\nSystem configuration\n====================\n";

print STDERR "\$^O = $^O; \$] = $]\n";

print STDERR "xs_cpusetGetCpuCOUNT\n"
	if defined &Sys::CpuAffinity::xs_cpusetGetCPUCount;
print STDERR "xs_get_numcpus_from_windows_system_info\n"
	if defined &Sys::CpuAffinity::xs_get_numcpus_from_windows_system_info;
print STDERR "xs_get_numcpus_from_windows_system_info_alt\n"
	if defined &Sys::CpuAffinity::xs_get_numcpus_from_windows_system_info_alt;
print STDERR "xs_sched_getaffinity_get_affinity\n"
	if defined &Sys::CpuAffinity::xs_sched_getaffinity_get_affinity;
print STDERR "xs_getaffinity_process_bind\n"
	if defined &Sys::CpuAffinity::xs_getaffinity_process_bind;
print STDERR "xs_getaffinity_cpuset_get_affinity\n"
	if defined &Sys::CpuAffinity::xs_getaffinity_cpuset_get_affinity;
print STDERR "xs_sched_setaffinity_set_affinity\n"
	if defined &Sys::CpuAffinity::xs_sched_setaffinity_set_affinity;
print STDERR "xs_setaffinity_processor_unbind\n"
	if defined &Sys::CpuAffinity::xs_setaffinity_processor_unbind;
print STDERR "xs_setaffinity_process_bind\n"
	if defined &Sys::CpuAffinity::xs_setaffinity_process_bind;
print STDERR "xs_cpuset_set_affinity\n"
	if defined &Sys::CpuAffinity::xs_cpuset_set_affinity;

foreach my $module (qw(Win32::API Win32::Process BSD::Process::Affinity)) {
	my $avail = Sys::CpuAffinity::_configModule($module);
	print STDERR "module $module: ", $avail && "not ", "available\n";
}

foreach my $externalProgram (qw(bindprocessor dmesg sysctl psrinfo
	hinv hwprefs prtconf taskset pbind cpuset)) {

	my $path = Sys::CpuAffinity::_configExternalProgram($externalProgram);
	if ($path) {
		print STDERR "$externalProgram available at $path\n";
	} else {
		print STDERR "$externalProgram: not found\n";
	}
}

ok(1);
