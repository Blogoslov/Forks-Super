#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>


MODULE = Sys::CpuAffinity        PACKAGE = Sys::CpuAffinity

SV*
xs_hello()
  CODE:
    SV* r = newSVpv("hello, world", 12);
    RETVAL = r;
  OUTPUT:
    RETVAL

