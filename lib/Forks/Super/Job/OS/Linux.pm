#
# Forks::Super::Job::OS::Linux - operating system manipulation for Linux
#

package Forks::Super::Job::OS::Linux;
use Forks::Super::Config ':all';
use Forks::Super::Debug ':all';
use Carp;
use strict;
use warnings;
$| = 1;

our $WORKAROUND = "";
our $INLINE_AVAIL = 0;

if ($^O !~ /linux/i) {
  # compiling the inline C code outside of Linux
  # will probably get you before this does ...
  croak "Loading Linux-only module into $^O\n";
}

*Forks::Super::Job::OS::set_cpu_affinity = *set_cpu_affinity;

######################################################################
# if Inline::C module is available, we'll (attempt to) compile
# and bind some helpful functionality. But if it's not, we'll
# still be OK.

my $code = <<'__CONDITIONAL_CODE__';
#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <linux/unistd.h>
#define MAX_CPU 16

cpu_set_t *set1;
cpu_set_t *set2;
cpu_set_t set3, set4;
int initialized = 0;

void init()
{
    if (initialized++) return;
    set1 = &set3;
    set2 = &set4;
}


int set_linux_cpu_affinity_inline_c(int pid, int cpumask)
{
  int i,r2;
  cpu_set_t *the_cpu_set;

  init();
  the_cpu_set = set1;

  CPU_ZERO(the_cpu_set);
  for (i = 0; i < 32 && i < MAX_CPU; i++) {
    if ((cpumask & (1 << i)) != 0) {
      CPU_SET(i, the_cpu_set);
    } else {
      CPU_CLR(i, the_cpu_set);
    }
  }
  r2 = sched_setaffinity(pid, MAX_CPU, the_cpu_set);
  return r2;
}

int get_linux_cpu_affinity_debug(int pid)
{
    int i, r, z;

    init();
    fprintf(stderr, "CPU_SETSIZE is %d.\n", CPU_SETSIZE);

    z = sched_getaffinity(pid, CPU_SETSIZE, set1);
    for (i = r = 0; i < MAX_CPU && i < MAX_CPU; i++) {
	if (CPU_ISSET(i, set1)) {
	    fprintf(stderr, "CPU#%d: ON\n", i);
	    r |= 1 << i;
	} else {
	    fprintf(stderr, "CPU#%d: off\n", i);
	}
    }
    if (z) {
	if (errno == ESRCH) {
	    fprintf(stderr, "r: ESRCH\n");
	} else if (errno == EFAULT) {
	    fprintf(stderr, "r: EFAULT\n");
	} else {
	    fprintf(stderr, "r: E_WTF %d %d\n", z, errno);
	}
	return -1;
    }

    fprintf(stderr, "getaffinity: returning %d\n", r);
    return r;
}

int get_linux_cpu_affinity_inline_c(int pid)
{
    int i, r, z;

    init();
    z = sched_getaffinity(pid, CPU_SETSIZE, set2);
    if (z) {
	return -1;
    }
    for (i = r = 0; i < MAX_CPU && i < CPU_SETSIZE; i++) {
	if (CPU_ISSET(i, set2)) {
	    r |= 1 << i;
	}
    }
    return r;
}

int set_linux_cpu_affinity_debug(int pid, int cpumask)
{
  int i,r2,r3;
  cpu_set_t *the_cpu_set;
  cpu_set_t *old_cpu_set;

  fprintf(stderr, "setting affinity %d %d\n", pid, cpumask);
  init();
  the_cpu_set = set1;
  old_cpu_set = set2;

  fprintf(stderr, "pid=%d, mask=0x%x\n", pid, cpumask);

  CPU_ZERO(the_cpu_set);
  for (i = 0; i < MAX_CPU && i < MAX_CPU; i++) {
    if ((cpumask & (1 << i)) != 0) {
      CPU_SET(i, the_cpu_set);
      fprintf(stderr, "Enable CPU#%d\n", i);
    }
  }

  r2 = sched_setaffinity(pid, MAX_CPU, the_cpu_set);
  fprintf(stderr, "r2=%d\n", r2);
  if (r2) {
      if (errno == EFAULT) {
	  fprintf(stderr, "r2: EFAULT\n");
      } else if (errno == ESRCH) {
	  fprintf(stderr, "r2: ESRCH\n");
      } else if (errno == EINVAL) {
	  fprintf(stderr, "r2: EINVAL\n");
      } else {
	  fprintf(stderr, "r2: E_WTF\n");
      }
  }
  return r2;
}

__CONDITIONAL_CODE__
;

eval<<'__END_EVAL__';
require Inline;
Inline->bind('C', $code);
__END_EVAL__
if ($@) {
  if ($DEBUG) {
    carp "Inline C code not available: $@\n";
  } else {
    carp "Inline C code not available.\n";
  }
  *set_linux_cpu_affinity_inline_c = sub { return 0 };
  *get_linux_cpu_affinity_inline_c = sub { return -1 };
  if ($@ =~ /Can't locate .* in \@INC/) { #';
      $WORKAROUND = "Consider installing the Inline::C module.";
  } elsif ($@ =~ /_\d{4}\.o:\S+_\d{4}\.c:/) {
      $WORKAROUND = "Link error in inline code";
  } elsif ($@ =~ /_\d{4}\.xs:\d+:/) {
      $WORKAROUND = "Compile error in inline code";
  } else {
    $WORKAROUND = "Fix unspecified error in inline code";
  }
} else {
  $INLINE_AVAIL = 1;
  *set_linux_cpu_affinity = *set_linux_cpu_affinity_inline_c;
  *get_linux_cpu_affinity = *get_linux_cpu_affinity_inline_c;
}

######################################################################

sub set_cpu_affinity_fail {
  my $pid = shift;
  carp "Forks::Super::Job:config_os_child: ",
    "setting cpu affinity for process $pid may have failed. $WORKAROUND\n";
  return 0;
}

sub set_cpu_affinity_taskset {
  my ($pid, $mask) = @_;
  if (CONFIG("/taskset")) {
    my $n = sprintf '0%o', $mask;
    my $c1 = system(CONFIG("/taskset"), '-p', $n, $pid);
    return $c1 == 0;
  } else {
    $WORKAROUND .= "/ put Linux utility taskset(2) on the \$PATH";
  }
  return 0;
}

sub set_cpu_affinity {
  my $job = shift;
  my $bitmask = $job->{cpu_affinity};
  $WORKAROUND = "";

  return 
    ($INLINE_AVAIL && set_linux_cpu_affinity_inline_c($$, $bitmask))
    || set_cpu_affinity_taskset($$, $bitmask)
    || set_cpu_affinity_fail($$);
}

######################################################################

1;
__END__
__C__

int dummy;
