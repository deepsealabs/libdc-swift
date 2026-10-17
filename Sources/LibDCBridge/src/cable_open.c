#include "configuredc.h"

#if TARGET_OS_OSX
#include <string.h>
#include <libdivecomputer/serial.h>
#include "bridge_private.h"

dc_status_t open_serial_device(device_data_t *data, const char *path, dc_family_t family, unsigned int model,
    libdc_iostream_wrap_t wrap, void *wrap_userdata) {
    if (!data) {
        return DC_STATUS_INVALIDARGS;
    }

    dc_context_t *context = data->context;
    memset(data, 0, sizeof(device_data_t));
    if (!context) {
        return DC_STATUS_INVALIDARGS;
    }
    if (!path) {
        dc_context_free(context);
        return DC_STATUS_INVALIDARGS;
    }
    libdc_configure_context_logging(context);

    // Resolved first: opening the port raises DTR, which powers or wakes many cables.
    dc_descriptor_t *descriptor = NULL;
    dc_status_t rc = find_descriptor_by_model(&descriptor, family, model);
    if (rc != DC_STATUS_SUCCESS) {
        dc_context_free(context);
        return rc;
    }
    dc_descriptor_free(descriptor);

    dc_iostream_t *iostream = NULL;
    rc = dc_serial_open(&iostream, context, path);
    if (rc != DC_STATUS_SUCCESS) {
        dc_context_free(context);
        return rc;
    }

    if (wrap) {
        iostream = wrap(context, iostream, wrap_userdata);
        if (!iostream) {
            dc_context_free(context);
            return DC_STATUS_NOMEMORY;
        }
    }

    data->context = context;
    return open_device_on_iostream(data, iostream, family, model, LIBDC_SERIAL_OPEN_ATTEMPTS, 0);
}
#endif
