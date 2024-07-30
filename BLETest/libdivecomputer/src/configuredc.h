#ifndef CONFIGUREDC_H
#define CONFIGUREDC_H

#include <stdbool.h>
#include "libdivecomputer/common.h"
#include "libdivecomputer/iostream.h"
#include "libdivecomputer/context.h"
#include "suunto_eonsteel.h"

typedef struct {
    dc_device_t *device;
    dc_context_t *context;
    dc_iostream_t *iostream;
} device_data_t;

typedef struct ble_object ble_object_t;

// Function declarations
dc_status_t ble_open(dc_iostream_t **iostream, dc_context_t *context, const char *devaddr);
dc_status_t open_suunto_eonsteel(device_data_t *data, const char *devaddr);

#endif /* CONFIGUREDC_H */
