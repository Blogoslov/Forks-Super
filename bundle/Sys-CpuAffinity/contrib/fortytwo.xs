#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity

int
xs_fortytwo()
  /* this function is only here to see if ANYTHING can compile */
  CODE:
    RETVAL = 42;
  OUTPUT:
    RETVAL




