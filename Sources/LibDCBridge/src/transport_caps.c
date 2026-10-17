#include "configuredc.h"

#ifdef HAVE_IOKIT_SERIAL_IOSS_H
#include <IOKit/serial/ioss.h>
#endif

// Same macro serial_posix.c tests before returning DC_STATUS_UNSUPPORTED for a non-standard rate.
bool libdc_has_custom_baud(void)
{
#if defined(IOSSIOSPEED)
    return true;
#else
    return false;
#endif
}
