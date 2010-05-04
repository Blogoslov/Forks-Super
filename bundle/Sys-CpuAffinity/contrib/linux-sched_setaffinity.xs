#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <linux/unistd.h>
#define MAX_CPU 2
cpu_set_t sched_setaffinity_set2;
int sched_setaffinity_set_affinity(int pid, int cpumask)
{
    cpu_set_t mask;
    unsigned int len = sizeof(mask);
    int i,r;

    CPU_ZERO(&mask);
    for (i=0; i<32 && i<CPU_SETSIZE; i++) {
	if (0 != (cpumask & (1 << i))) {
	    CPU_SET(i, &mask);
	}
    }
    r = sched_setaffinity(pid, len, &mask);
if (r != 0) {
    fprintf(stderr,"result: %d %d %s\n", r, errno,
	    errno==EFAULT ? "EFAULT"
	    : errno==EINVAL ? "EINVAL"
	    : errno==EPERM ? "EPERM"
	    : errno==ESRCH ? "ESRCH":"E_WTF");
}
    return !r; /* sched_setaffinity: 0 on success */
}


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity

int
xs_sched_setaffinity_set_affinity(pid,mask)
	int pid
	int mask
    CODE:
	RETVAL = sched_setaffinity_set_affinity(pid,mask);
    OUTPUT:
	RETVAL




