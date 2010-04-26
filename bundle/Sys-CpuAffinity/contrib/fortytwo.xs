#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity

int
xs_fortytwo()
  CODE:
    RETVAL = 42;
  OUTPUT:
    RETVAL




