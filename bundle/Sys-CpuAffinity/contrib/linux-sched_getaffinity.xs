#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include <linux/unistd.h>
#include <sched.h>

/*
 * This declaration isn't used and looks useless. But for some
 * reason I don't understand at all, for some versions of perl
 * with some build configurations running on some systems,
 * this declaration is the difference between XS code that works
 * (specifically, passing t/11-exercise-all.t) and code that
 * segfaults. For the same reason, the  cpu_set_t  variables
 * in  xs_sched_getaffinity_get_affinity()  below are declared
 * static . 
 *
 * Any insights into this issue would be profoundly appreciated.
 */
char ___linux_sched_getaffinity_dummy[4096];


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity


int
xs_sched_getaffinity_get_affinity(pid,debug_flag)
	int pid
	int debug_flag
  CODE:
    int i, r, z;
    static cpu_set_t _set2, *_set1;

    if(debug_flag) fprintf(stderr,"getaffinity0\n");
    _set1 = &_set2;
    if(debug_flag) fprintf(stderr,"getaffinity1 pid=%d size=%d cpuset=0x%d\n",
	  (int) pid, (int) CPU_SETSIZE, (int) _set1);
    z = sched_getaffinity((pid_t) pid, CPU_SETSIZE, _set1);
    if(debug_flag) fprintf(stderr,"getaffinity2\n");
    if (z) {
      if(debug_flag) fprintf(stderr,"getaffinity3 z=%d err=%d\n", z, errno);
      r = 0;
    } else {
      if(debug_flag) fprintf(stderr,"getaffinity5\n");
      for (i = r = 0; i < CPU_SETSIZE && i < 32; i++) {
        if(debug_flag) fprintf(stderr,"getaffinity6 i=%d r=%d\n", i, r);
        if (CPU_ISSET(i, &_set2)) {
          if(debug_flag) fprintf(stderr,"getaffinity7\n");
          r |= 1 << i;
          if(debug_flag) fprintf(stderr,"getaffinity8 r=%d\n", r);
        }
        if(debug_flag) fprintf(stderr,"getaffinity9\n");
      }
      if(debug_flag) fprintf(stderr,"getaffinitya\n");
    }
    RETVAL = r;
  OUTPUT:
    RETVAL




