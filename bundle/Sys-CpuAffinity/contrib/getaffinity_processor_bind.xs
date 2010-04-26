#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include <sys/types.h>
#include <sys/processor.h>
#include <sys/procset.h>
int getaffinity_processor_bind(int pid)
{
  int r,z;
  idtype_t idtype = P_PID;
  id_t id = (id_t) pid;
  processorid_t processorid = PBIND_QUERY;
  processorid_t obind;
  r = processor_bind(idtype, id, processorid, &obind);
  if (r != 0) {
    if (errno == EFAULT) {
      fprintf(stderr,"getaffinity_processor_bind: error code EFAULT\n");
      return 0;
    } else if (errno == EINVAL) {
      fprintf(stderr,"getaffinity_processor_bind: error code EINVAL\n");
      return 0;
    } else if (errno == EPERM) {
      fprintf(stderr,"getaffinity_processor_bind: no permission to pbind %d\n",
	      pid);
      return 0;
    } else if (errno == ESRCH) {
      fprintf(stderr,"getaffinity_processor_bind: no such PID %d\n", pid);
      return 0;
    } else {
      fprintf(stderr,"getaffinity_processor_bind: unknown error %d\n", errno);
      return 0;
    }
  }
  /* is  obind  a bitmask? or is it just the value of a single CPU index ? */
  if (obind == PBIND_NONE) {
    obind = -10;
  }
  return obind;
}


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity


int
xs_getaffinity_processor_bind(pid)
	int pid
    CODE:
	RETVAL = getaffinity_processor_bind(pid);
    OUTPUT:
	RETVAL



