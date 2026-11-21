#ifndef LIBDC_BRIDGE_PRIVATE_H
#define LIBDC_BRIDGE_PRIVATE_H

#include <TargetConditionals.h>
#include <libdivecomputer/context.h>

#if TARGET_OS_OSX
/** The bridge's log callback and level (set_ble_debug_logging), as open_device_on_iostream sets them */
void libdc_configure_context_logging(dc_context_t *context);
#endif

#endif /* LIBDC_BRIDGE_PRIVATE_H */
