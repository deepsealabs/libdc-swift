#include "configuredc.h"
#include <TargetConditionals.h>

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

// Native macOS only: TARGET_OS_OSX is 0 on iOS and Mac Catalyst, like the .macOS-only serial defines.
#if TARGET_OS_OSX
#define LIBDC_CABLE_TRANSPORTS (DC_TRANSPORT_SERIAL | DC_TRANSPORT_USBHID | DC_TRANSPORT_USB)
#else
#define LIBDC_CABLE_TRANSPORTS DC_TRANSPORT_NONE
#endif

#if TARGET_OS_IPHONE
_Static_assert(LIBDC_CABLE_TRANSPORTS == DC_TRANSPORT_NONE, "iOS builds must report no cable transports");
#endif

unsigned int libdc_cable_transports(void)
{
    return LIBDC_CABLE_TRANSPORTS;
}
