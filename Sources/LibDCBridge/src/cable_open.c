#include "configuredc.h"

#if TARGET_OS_OSX
#include <string.h>
#include <libdivecomputer/serial.h>
#include "bridge_private.h"

typedef dc_status_t (*libdc_port_open_t)(dc_iostream_t **iostream, dc_context_t *context, const char *path, unsigned int limit);

static dc_status_t libdc_open_posix_port(dc_iostream_t **iostream, dc_context_t *context, const char *path, unsigned int limit)
{
    return dc_serial_open(iostream, context, path);
}

static dc_status_t open_port_device(device_data_t *data, const char *path, dc_family_t family, unsigned int model,
    libdc_port_open_t open_port, unsigned int limit, libdc_iostream_wrap_t wrap, void *wrap_userdata) {
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

    // A wrapped port logs on its own context, WARNING and up (the port's errno lines): its INFO lines would repeat
    // every call the wrapper logs, and the wrapper's 50 ms cancel slices would add a poll or sleep line each.
    dc_context_t *port_context = context;
    if (wrap) {
        port_context = NULL;
        if (dc_context_new(&port_context) != DC_STATUS_SUCCESS || !port_context) {
            dc_context_free(context);
            return DC_STATUS_NOMEMORY;
        }
        libdc_configure_context_logging(port_context);
        dc_context_set_loglevel(port_context, DC_LOGLEVEL_WARNING);
    }

    dc_iostream_t *iostream = NULL;
    rc = open_port(&iostream, port_context, path, limit);
    if (rc != DC_STATUS_SUCCESS) {
        if (port_context != context) {
            dc_context_free(port_context);
        }
        dc_context_free(context);
        return rc;
    }

    if (wrap) {
        iostream = wrap(context, iostream, wrap_userdata);
        if (!iostream) {
            dc_context_free(port_context);
            dc_context_free(context);
            return DC_STATUS_NOMEMORY;
        }
    }

    data->context = context;
    rc = open_device_on_iostream(data, iostream, family, model, LIBDC_SERIAL_OPEN_ATTEMPTS, 0);
    if (port_context != context) {
        if (rc == DC_STATUS_SUCCESS) {
            data->stream_context = port_context;
        } else {
            // open_device_on_iostream closed the stream, and the port with it.
            dc_context_free(port_context);
        }
    }
    return rc;
}

dc_status_t open_serial_device(device_data_t *data, const char *path, dc_family_t family, unsigned int model,
    libdc_iostream_wrap_t wrap, void *wrap_userdata) {
    return open_port_device(data, path, family, model, libdc_open_posix_port, 0, wrap, wrap_userdata);
}

dc_status_t open_btserial_device(device_data_t *data, const char *path, dc_family_t family, unsigned int model,
    unsigned int write_limit_ms, libdc_iostream_wrap_t wrap, void *wrap_userdata) {
    return open_port_device(data, path, family, model, libdc_btserial_open, write_limit_ms, wrap, wrap_userdata);
}
#endif
