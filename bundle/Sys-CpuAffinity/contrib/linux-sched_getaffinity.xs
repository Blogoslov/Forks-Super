#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <linux/unistd.h>
cpu_set_t *sched_getaffinity_set1;
cpu_set_t sched_getaffinity_set2;
int sched_getaffinity_initialized = 0;
void sched_getaffinity_initialize()
{
  if (sched_getaffinity_initialized++) return;
  sched_getaffinity_set1 = &sched_getaffinity_set2;
}
int sched_getaffinity_get_affinity_debug(int pid)
{
  int i, r, z;
fprintf(stderr,"getaffinity0\n");
  sched_getaffinity_initialize();
fprintf(stderr,"getaffinity1\n");
  z = sched_getaffinity((pid_t) pid, CPU_SETSIZE, sched_getaffinity_set1);
fprintf(stderr,"getaffinity2\n");
  if (z) {
fprintf(stderr,"getaffinity3\n");
    return 0;
fprintf(stderr,"getaffinity4\n");
  }
fprintf(stderr,"getaffinity5\n");
  for (i = r = 0; i < CPU_SETSIZE && i < 16; i++) {
fprintf(stderr,"getaffinity6\n");
   if (CPU_ISSET(i, &sched_getaffinity_set2)) {
fprintf(stderr,"getaffinity7\n");
      r |= 1 << i;
fprintf(stderr,"getaffinity8\n");
    }
fprintf(stderr,"getaffinity9\n");
  }
fprintf(stderr,"getaffinitya\n");
  return r;
}
int sched_getaffinity_get_affinity_no_debug(int pid)
{
  int i, r, z;
  sched_getaffinity_initialize();
  z = sched_getaffinity((pid_t) pid, CPU_SETSIZE, sched_getaffinity_set1);
  if (z) {
    return 0;
  }
  for (i = r = 0; i < CPU_SETSIZE && i < 16; i++) {
    if (CPU_ISSET(i, &sched_getaffinity_set2 )) {
      r |= 1 << i;
    }
  }
  return r;
}

MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity


int 
xs_sched_getaffinity_get_affinity(pid)
int pid
    CODE:
	RETVAL = sched_getaffinity_get_affinity_no_debug(pid);
    OUTPUT:
	RETVAL

