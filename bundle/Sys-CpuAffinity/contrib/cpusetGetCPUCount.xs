#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include <cpuset.h>


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity

int
xs_cpusetGetCPUCount()
    CODE:
        int ncpus = cpusetGetCPUCount();
	RETVAL = ncpus;
    OUTPUT:
	RETVAL

