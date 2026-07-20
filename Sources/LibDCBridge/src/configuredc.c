#include "configuredc.h"
#include "BLEBridge.h"
#include <libdivecomputer/device.h>
#include <libdivecomputer/descriptor.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/parser.h>
#include "iostream-private.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/*--------------------------------------------------------------------
 * BLE stream structures
 *------------------------------------------------------------------*/
typedef struct ble_stream_t {
    dc_iostream_t base;
    ble_object_t *ble_object;
} ble_stream_t;

/*--------------------------------------------------------------------
 * Forward declarations for our custom vtable
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_set_timeout   (dc_iostream_t *iostream, int timeout);
static dc_status_t ble_stream_read          (dc_iostream_t *iostream, void *data, size_t size, size_t *actual);
static dc_status_t ble_stream_write         (dc_iostream_t *iostream, const void *data, size_t size, size_t *actual);
static dc_status_t ble_stream_ioctl         (dc_iostream_t *iostream, unsigned int request, void *data_, size_t size_);
static dc_status_t ble_stream_sleep         (dc_iostream_t *iostream, unsigned int milliseconds);
static dc_status_t ble_stream_close         (dc_iostream_t *iostream);

/*--------------------------------------------------------------------
 * Build custom vtable
 *------------------------------------------------------------------*/
static const dc_iostream_vtable_t ble_iostream_vtable = {
    .size          = sizeof(dc_iostream_vtable_t),
    .set_timeout   = ble_stream_set_timeout,
    .set_break     = NULL,
    .set_dtr       = NULL,
    .set_rts       = NULL,
    .get_lines     = NULL,
    .get_available = NULL,
    .configure     = NULL,
    .poll          = NULL,
    .read          = ble_stream_read,
    .write         = ble_stream_write,
    .ioctl         = ble_stream_ioctl,
    .flush         = NULL,
    .purge         = NULL,
    .sleep         = ble_stream_sleep,
    .close         = ble_stream_close,
};

/*--------------------------------------------------------------------
 * Helper to print hex dumps for debugging
 *------------------------------------------------------------------*/
static void debug_hexdump(const char *prefix, const void *data, size_t size) {
    const unsigned char *p = (const unsigned char *)data;
    printf("DC_IO [%s] (%zu bytes): ", prefix, size);
    for (size_t i = 0; i < size; i++) {
        printf("%02X ", p[i]);
    }
    printf("\n");
}

/*--------------------------------------------------------------------
 * Creates a BLE iostream instance
 *------------------------------------------------------------------*/
static dc_status_t ble_iostream_create(dc_iostream_t **out, dc_context_t *context, ble_object_t *bleobj)
{
    ble_stream_t *stream = (ble_stream_t *) malloc(sizeof(ble_stream_t));
    if (!stream) {
        if (context) {
            printf("ble_iostream_create: no memory\n");
        }
        return DC_STATUS_NOMEMORY;
    }
    memset(stream, 0, sizeof(*stream));

    stream->base.vtable = &ble_iostream_vtable;
    stream->base.context = context;
    stream->base.transport = DC_TRANSPORT_BLE;
    stream->ble_object = bleobj;

    *out = (dc_iostream_t *)stream;
    return DC_STATUS_SUCCESS;
}

/*--------------------------------------------------------------------
 * Sets the timeout for BLE operations
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_set_timeout(dc_iostream_t *iostream, int timeout)
{
    // Uncomment to debug timeout changes, usually too verbose
    // printf("DC_IO [TIMEOUT] Setting to %d ms\n", timeout);
    ble_stream_t *s = (ble_stream_t *) iostream;
    return ble_set_timeout(s->ble_object, timeout);
}

/*--------------------------------------------------------------------
 * Reads data from the BLE device
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_read(dc_iostream_t *iostream, void *data, size_t size, size_t *actual)
{
    ble_stream_t *s = (ble_stream_t *) iostream;
    dc_status_t rc = ble_read(s->ble_object, data, size, actual);

    if (rc == DC_STATUS_SUCCESS && actual && *actual > 0) {
        // printf("DC_IO [READ_DEBUG] Requested: %zu, Received: %zu, Transport: %d\n",
        //        size, *actual, iostream->transport);
        // debug_hexdump("READ", data, *actual);

        // For BLE transport, show what would be processed after skipping header
        if (iostream->transport == DC_TRANSPORT_BLE && *actual >= 2) {
            // printf("DC_IO [READ_DEBUG] After BLE header skip (first 2 bytes):\n");
            // debug_hexdump("READ_AFTER_SKIP", (unsigned char*)data + 2, *actual - 2);

            // Show the expected packet structure
            unsigned char *packet = (unsigned char*)data;
            if (*actual >= 6) {
                // printf("DC_IO [READ_DEBUG] BLE Header: [0]=0x%02X [1]=0x%02X\n", packet[0], packet[1]);
                // printf("DC_IO [READ_DEBUG] SLIP Packet: [2]=0x%02X [3]=0x%02X [4]=0x%02X [5]=0x%02X\n",
                //        packet[2], packet[3], packet[4], packet[5]);

                // If this looks like a response packet (starts with 01 FF at offset 2)
                if (packet[2] == 0x01 && packet[3] == 0xFF && *actual >= 7) {
                    unsigned int length = packet[4];
                    // printf("DC_IO [READ_DEBUG] Length field: 0x%02X (%u decimal)\n", length, length);
                    // printf("DC_IO [READ_DEBUG] Expected total size: %u (length-1+4) = %u\n",
                    //        length, length - 1 + 4);
                    // printf("DC_IO [READ_DEBUG] Actual size after BLE skip: %zu\n", *actual - 2);
                    // printf("DC_IO [READ_DEBUG] Difference: %zd bytes\n", (*actual - 2) - (length - 1 + 4));
                }
            }
        }
    }

    return rc;
}

/*--------------------------------------------------------------------
 * Writes data to the BLE device
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_write(dc_iostream_t *iostream, const void *data, size_t size, size_t *actual)
{
    // Log all writes
    // debug_hexdump("WRITE", data, size);
    
    ble_stream_t *s = (ble_stream_t *) iostream;
    return ble_write(s->ble_object, data, size, actual);
}

/*--------------------------------------------------------------------
 * Performs device-specific control operations
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_ioctl(dc_iostream_t *iostream, unsigned int request, void *data_, size_t size_)
{
    ble_stream_t *s = (ble_stream_t *) iostream;
    return ble_ioctl(s->ble_object, request, data_, size_);
}

/*--------------------------------------------------------------------
 * Suspends execution for specified duration
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_sleep(dc_iostream_t *iostream, unsigned int milliseconds)
{
    // printf("DC_IO [SLEEP] %u ms\n", milliseconds);
    ble_stream_t *s = (ble_stream_t *) iostream;
    return ble_sleep(s->ble_object, milliseconds);
}

/*--------------------------------------------------------------------
 * Closes the BLE stream and frees resources
 *------------------------------------------------------------------*/
static dc_status_t ble_stream_close(dc_iostream_t *iostream)
{
    ble_stream_t *s = (ble_stream_t *) iostream;
    dc_status_t rc = ble_close(s->ble_object);
    freeBLEObject(s->ble_object);
    // Do NOT free(s) here — dc_iostream_close calls dc_iostream_deallocate
    // after this vtable close returns, which frees the iostream memory.
    // Freeing here causes a double-free crash (POINTER_BEING_FREED_WAS_NOT_ALLOCATED).
    return rc;
}

/*--------------------------------------------------------------------
 * Opens a BLE packet connection to a dive computer
 *------------------------------------------------------------------*/
dc_status_t ble_packet_open(dc_iostream_t **iostream, dc_context_t *context, const char *devaddr, void *userdata) {
    // Initialize the Swift BLE manager singletons
    initializeBLEManager();

    // Create a BLE object
    ble_object_t *io = createBLEObject();
    if (io == NULL) {
        printf("ble_packet_open: Failed to create BLE object\n");
        return DC_STATUS_NOMEMORY;
    }

    // Connect to the device
    if (!connectToBLEDevice(io, devaddr)) {
        printf("ble_packet_open: Failed to connect to device\n");
        freeBLEObject(io);
        return DC_STATUS_IO;
    }

    // Create a custom BLE iostream
    dc_status_t status = ble_iostream_create(iostream, context, io);
    if (status != DC_STATUS_SUCCESS) {
        printf("ble_packet_open: Failed to create iostream\n");
        freeBLEObject(io);
        return status;
    }

    return DC_STATUS_SUCCESS;
}

/*--------------------------------------------------------------------
 * Event callback wrapper
 *------------------------------------------------------------------*/
static void ble_device_event_cb(dc_device_t *device, dc_event_type_t event, const void *data, void *userdata)
{
    device_data_t *devdata = (device_data_t *)userdata;
    if (!devdata) return;
    
    switch (event) {
    case DC_EVENT_DEVINFO:
        {
            const dc_event_devinfo_t *devinfo = (const dc_event_devinfo_t *)data;
            devdata->devinfo = *devinfo;
            devdata->have_devinfo = 1;
            
            // Look up fingerprint using callback if available
            if (devdata->lookup_fingerprint && devdata->model) {
                char serial[16];
                snprintf(serial, sizeof(serial), "%08x", devinfo->serial);
                
                size_t fsize = 0;
                unsigned char *fingerprint = devdata->lookup_fingerprint(
                    devdata->fingerprint_context,
                    devdata->model,
                    serial,
                    &fsize
                );
                
                if (fingerprint && fsize > 0) {
                    printf("[C] Setting fingerprint on device: ");
                    for (size_t i = 0; i < fsize; i++) {
                        printf("0x%02x ", fingerprint[i]);
                    }
                    printf("(size=%zu)\n", fsize);

                    dc_status_t fp_status = dc_device_set_fingerprint(device, fingerprint, fsize);
                    printf("[C] dc_device_set_fingerprint returned: %d\n", fp_status);

                    devdata->fingerprint = fingerprint;
                    devdata->fsize = fsize;
                } else {
                    printf("[C] No fingerprint returned from callback (fingerprint=%p, fsize=%zu)\n",
                           (void*)fingerprint, fsize);
                }
            }
        }
        break;
    case DC_EVENT_PROGRESS:
        {
            const dc_event_progress_t *progress = (const dc_event_progress_t *)data;
            devdata->progress = *progress;
            devdata->have_progress = 1;
        }
        break;
    default:
        break;
    }
}

/*--------------------------------------------------------------------
 * Closes and frees resources associated with a device_data structure
 *------------------------------------------------------------------*/
static void close_device_data(device_data_t *data) {
    if (!data) return;
            
    if (data->fingerprint) {
        free(data->fingerprint);
        data->fingerprint = NULL;
        data->fsize = 0;
    }
    
    if (data->model) {
        free((void*)data->model);
        data->model = NULL;
    }
    
    if (data->device) {
        dc_device_close(data->device);
        data->device = NULL;
    }
    if (data->iostream) {
        dc_iostream_close(data->iostream);
        data->iostream = NULL;
    }
    if (data->context) {
        dc_context_free(data->context);
        data->context = NULL;
    }
    data->descriptor = NULL;
}

/*--------------------------------------------------------------------
 * Opens a BLE device using a provided descriptor
 *------------------------------------------------------------------*/
// Forwards libdivecomputer's internal ERROR/WARNING/INFO/DEBUG logging
// (context-private.h, only compiled in with ENABLE_LOGGING — see Package.swift)
// to the console with printf, matching the existing "[C] ..." print pattern
// elsewhere in this file. Without this, a protocol-level validation failure
// in e.g. shearwater_common.c only ever surfaces as a bare DC_STATUS_PROTOCOL,
// with no indication of which specific check failed or why.
static void dc_log_callback(dc_context_t *context, dc_loglevel_t loglevel, const char *file, unsigned int line, const char *function, const char *message, void *userdata) {
    const char *level = "?";
    switch (loglevel) {
        case DC_LOGLEVEL_ERROR:   level = "ERROR"; break;
        case DC_LOGLEVEL_WARNING: level = "WARN"; break;
        case DC_LOGLEVEL_INFO:    level = "INFO"; break;
        case DC_LOGLEVEL_DEBUG:   level = "DEBUG"; break;
        default: break;
    }
    printf("[C][libdc:%s] %s:%d %s(): %s\n", level, file, line, function, message);
}

dc_status_t open_ble_device(device_data_t *data, const char *devaddr, dc_family_t family, unsigned int model) {
    dc_status_t rc;
    dc_descriptor_t *descriptor = NULL;

    if (!data || !devaddr) {
        return DC_STATUS_INVALIDARGS;
    }

    // Initialize all pointers to NULL
    memset(data, 0, sizeof(device_data_t));

    // Create context
    rc = dc_context_new(&data->context);
    if (rc != DC_STATUS_SUCCESS) {
        printf("Failed to create context, rc=%d\n", rc);
        return rc;
    }
    dc_context_set_logfunc(data->context, dc_log_callback, NULL);

    // Get descriptor for the device
    rc = find_descriptor_by_model(&descriptor, family, model);
    if (rc != DC_STATUS_SUCCESS) {
        printf("Failed to find descriptor, rc=%d\n", rc);
        close_device_data(data);
        return rc;
    }

    // Create BLE iostream
    rc = ble_packet_open(&data->iostream, data->context, devaddr, data);
    if (rc != DC_STATUS_SUCCESS) {
        printf("Failed to open BLE connection, rc=%d\n", rc);
        close_device_data(data);
        return rc;
    }

    // Use dc_device_open to handle device-specific opening
    rc = dc_device_open(&data->device, data->context, descriptor, data->iostream);
    if (rc != DC_STATUS_SUCCESS) {
        printf("Failed to open device, rc=%d\n", rc);
        close_device_data(data);
        return rc;
    }

    // Set up event handler
    unsigned int events = DC_EVENT_DEVINFO | DC_EVENT_PROGRESS | DC_EVENT_CLOCK;
    // Updated to use the renamed callback function
    rc = dc_device_set_events(data->device, events, ble_device_event_cb, data);
    if (rc != DC_STATUS_SUCCESS) {
        printf("Failed to set event handler, rc=%d\n", rc);
        close_device_data(data);
        return rc;
    }

    // Store the descriptor
    data->descriptor = descriptor;

    // Store model string from descriptor
    if (descriptor) {
        const char *vendor = dc_descriptor_get_vendor(descriptor);
        const char *product = dc_descriptor_get_product(descriptor);
        if (vendor && product) {
            // Allocate space for "Vendor Product"
            size_t len = strlen(vendor) + strlen(product) + 2;  // +2 for space and null terminator
            char *full_name = malloc(len);
            if (full_name) {
                snprintf(full_name, len, "%s %s", vendor, product);
                data->model = full_name;  // Store full name
            }
        }
    }

    return DC_STATUS_SUCCESS;
}

/*--------------------------------------------------------------------
 * Helper function to find a matching device descriptor
 *------------------------------------------------------------------*/
/*--------------------------------------------------------------------
 * Helper function to find a matching device descriptor
 *------------------------------------------------------------------*/
 dc_status_t find_descriptor_by_model(dc_descriptor_t **out_descriptor,
    dc_family_t family, unsigned int model) {
    
    dc_iterator_t *iterator = NULL;
    dc_descriptor_t *descriptor = NULL;
    dc_status_t rc;

    rc = dc_descriptor_iterator(&iterator);
    if (rc != DC_STATUS_SUCCESS) {
        printf("❌ Failed to create descriptor iterator: %d\n", rc);
        return rc;
    }

    while ((rc = dc_iterator_next(iterator, &descriptor)) == DC_STATUS_SUCCESS) {
        if (dc_descriptor_get_type(descriptor) == family &&
            dc_descriptor_get_model(descriptor) == model) {
            *out_descriptor = descriptor;
            dc_iterator_free(iterator);
            return DC_STATUS_SUCCESS;
        }
        dc_descriptor_free(descriptor);
    }

    printf("❌ No matching descriptor found for Family %d Model %d\n", family, model);
    dc_iterator_free(iterator);
    return DC_STATUS_UNSUPPORTED;
}

/*--------------------------------------------------------------------
 * Creates a dive data parser for a specific device model
 *------------------------------------------------------------------*/
dc_status_t create_parser_for_device(dc_parser_t **parser, dc_context_t *context,
    dc_family_t family, unsigned int model, const unsigned char *data, size_t size)
{
    dc_status_t rc;
    dc_descriptor_t *descriptor = NULL;

    rc = find_descriptor_by_model(&descriptor, family, model);
    if (rc != DC_STATUS_SUCCESS) {
        return rc;
    }

    // Create parser
    rc = dc_parser_new2(parser, context, descriptor, data, size);
    dc_descriptor_free(descriptor);

    return rc;
}

/*--------------------------------------------------------------------
 * Helper function to find a matching BLE device descriptor by name
 *------------------------------------------------------------------*/
struct name_pattern {
    const char *prefix;
    const char *vendor;
    const char *product;
    enum {
        MATCH_EXACT,    // Full string match
        MATCH_PREFIX,   // Prefix match only
        MATCH_CONTAINS  // Substring match
    } match_type;
};

// Define known name patterns - order matters, more specific patterns first
static const struct name_pattern name_patterns[] = {
    // Shearwater dive computers
    { "Predator", "Shearwater", "Predator", MATCH_EXACT },
    { "Perdix 2", "Shearwater", "Perdix 2", MATCH_EXACT },
    { "Petrel 3", "Shearwater", "Petrel 3", MATCH_EXACT },
    { "Petrel", "Shearwater", "Petrel 2", MATCH_EXACT },  // Both Petrel and Petrel 2 identify as "Petrel"
    { "Perdix", "Shearwater", "Perdix", MATCH_EXACT },
    { "Teric", "Shearwater", "Teric", MATCH_EXACT },
    { "Peregrine TX", "Shearwater", "Peregrine TX", MATCH_EXACT },
    { "Peregrine", "Shearwater", "Peregrine TX", MATCH_EXACT },  // BLE advertises as "Peregrine" but hardware is Peregrine TX
    { "NERD 2", "Shearwater", "NERD 2", MATCH_EXACT },
    { "NERD", "Shearwater", "NERD", MATCH_EXACT },
    { "Tern", "Shearwater", "Tern", MATCH_EXACT },
    
    // Suunto dive computers
    { "EON Steel", "Suunto", "EON Steel", MATCH_EXACT },
    { "Suunto D5", "Suunto", "D5", MATCH_EXACT },
    { "EON Core", "Suunto", "EON Core", MATCH_EXACT },
    
    // Scubapro dive computers
    { "G2", "Scubapro", "G2", MATCH_EXACT },
    { "HUD", "Scubapro", "G2 HUD", MATCH_EXACT },
    { "G3", "Scubapro", "G3", MATCH_EXACT },
    { "Aladin", "Scubapro", "Aladin Sport Matrix", MATCH_EXACT },
    { "A1", "Scubapro", "Aladin A1", MATCH_EXACT },
    { "A2", "Scubapro", "Aladin A2", MATCH_EXACT },
    { "Luna 2.0 AI", "Scubapro", "Luna 2.0 AI", MATCH_EXACT },
    { "Luna 2.0", "Scubapro", "Luna 2.0", MATCH_EXACT },
    
    // Mares dive computers
    { "Mares Genius", "Mares", "Genius", MATCH_EXACT },
    { "Sirius", "Mares", "Sirius", MATCH_EXACT },
    { "Quad Ci", "Mares", "Quad Ci", MATCH_EXACT },
    { "Puck4", "Mares", "Puck 4", MATCH_EXACT },
    
    // Cressi dive computers - use prefix matching
    { "CARESIO_", "Cressi", "Cartesio", MATCH_PREFIX },
    { "GOA_", "Cressi", "Goa", MATCH_PREFIX },
    { "Leonardo", "Cressi", "Leonardo 2.0", MATCH_CONTAINS },
    { "Donatello", "Cressi", "Donatello", MATCH_CONTAINS },
    { "Michelangelo", "Cressi", "Michelangelo", MATCH_CONTAINS },
    { "Neon", "Cressi", "Neon", MATCH_CONTAINS },
    { "Nepto", "Cressi", "Nepto", MATCH_CONTAINS },
    
    // Heinrichs Weikamp dive computers
    { "OSTC 3", "Heinrichs Weikamp", "OSTC Plus", MATCH_EXACT },
    { "OSTC s#", "Heinrichs Weikamp", "OSTC Sport", MATCH_EXACT },
    { "OSTC s ", "Heinrichs Weikamp", "OSTC Sport", MATCH_EXACT },
    { "OSTC 4-", "Heinrichs Weikamp", "OSTC 4", MATCH_EXACT },
    { "OSTC 2-", "Heinrichs Weikamp", "OSTC 2N", MATCH_EXACT },
    { "OSTC + ", "Heinrichs Weikamp", "OSTC 2", MATCH_EXACT },
    { "OSTC", "Heinrichs Weikamp", "OSTC 2", MATCH_EXACT },
    
    // Deepblu dive computers
    { "COSMIQ", "Deepblu", "Cosmiq+", MATCH_EXACT },
    
    // Oceans dive computers
    { "S1", "Oceans", "S1", MATCH_EXACT },
    
    // McLean dive computers
    { "McLean Extreme", "McLean", "Extreme", MATCH_EXACT },
    
    // Tecdiving dive computers
    { "DiveComputer", "Tecdiving", "DiveComputer.eu", MATCH_EXACT },
    
    // Ratio dive computers
    { "DS", "Ratio", "iX3M 2021 GPS Easy", MATCH_EXACT },
    { "IX5M", "Ratio", "iX3M 2021 GPS Easy", MATCH_EXACT },
    { "RATIO-", "Ratio", "iX3M 2021 GPS Easy", MATCH_EXACT }
};

dc_status_t find_descriptor_by_name(dc_descriptor_t **out_descriptor, const char *name) {
    dc_iterator_t *iterator = NULL;
    dc_descriptor_t *descriptor = NULL;
    dc_status_t rc;

    // First try to match against known patterns
    for (size_t i = 0; i < sizeof(name_patterns)/sizeof(name_patterns[0]); i++) {
        bool matches = false;
        
        switch (name_patterns[i].match_type) {
            case MATCH_EXACT:
                matches = (strstr(name, name_patterns[i].prefix) != NULL);
                break;
            case MATCH_PREFIX:
                matches = (strncmp(name, name_patterns[i].prefix,
                    strlen(name_patterns[i].prefix)) == 0);
                break;
            case MATCH_CONTAINS:
                matches = (strstr(name, name_patterns[i].prefix) != NULL);
                break;
        }

        if (matches) {
            // Create iterator to find matching descriptor
            rc = dc_descriptor_iterator(&iterator);
            if (rc != DC_STATUS_SUCCESS) {
                printf("❌ Failed to create descriptor iterator: %d\n", rc);
                return rc;
            }

            while ((rc = dc_iterator_next(iterator, &descriptor)) == DC_STATUS_SUCCESS) {
                const char *vendor = dc_descriptor_get_vendor(descriptor);
                const char *product = dc_descriptor_get_product(descriptor);

                if (vendor && product &&
                    strcmp(vendor, name_patterns[i].vendor) == 0 &&
                    strcmp(product, name_patterns[i].product) == 0) {
                    *out_descriptor = descriptor;
                    dc_iterator_free(iterator);
                    return DC_STATUS_SUCCESS;
                }
                dc_descriptor_free(descriptor);
            }
            dc_iterator_free(iterator);
        }
    }

    // Fall back to filter-based matching if no pattern match found
    rc = dc_descriptor_iterator(&iterator);
    if (rc != DC_STATUS_SUCCESS) {
        return rc;
    }

    while ((rc = dc_iterator_next(iterator, &descriptor)) == DC_STATUS_SUCCESS) {
        unsigned int transports = dc_descriptor_get_transports(descriptor);
        
        if ((transports & DC_TRANSPORT_BLE) &&
            dc_descriptor_filter(descriptor, DC_TRANSPORT_BLE, name)) {
            *out_descriptor = descriptor;
            dc_iterator_free(iterator);
            return DC_STATUS_SUCCESS;
        }
        dc_descriptor_free(descriptor);
    }

    dc_iterator_free(iterator);
    return DC_STATUS_UNSUPPORTED;
}

/*--------------------------------------------------------------------
 * Gets device family and model for a BLE device by name
 *------------------------------------------------------------------*/
dc_status_t get_device_info_from_name(const char *name, dc_family_t *family, unsigned int *model) {
    dc_descriptor_t *descriptor = NULL;
    dc_status_t rc;

    rc = find_descriptor_by_name(&descriptor, name);
    if (rc != DC_STATUS_SUCCESS) {
        return rc;
    }

    *family = dc_descriptor_get_type(descriptor);
    *model = dc_descriptor_get_model(descriptor);
    dc_descriptor_free(descriptor);
    return DC_STATUS_SUCCESS;
}

/*--------------------------------------------------------------------
 * Gets formatted display name for a device (vendor + product)
 *------------------------------------------------------------------*/
char* get_formatted_device_name(const char *name) {
    dc_descriptor_t *descriptor = NULL;
    dc_status_t rc;
    char *result = NULL;

    rc = find_descriptor_by_name(&descriptor, name);
    if (rc != DC_STATUS_SUCCESS) {
        return NULL;
    }

    const char *vendor = dc_descriptor_get_vendor(descriptor);
    const char *product = dc_descriptor_get_product(descriptor);
    
    if (vendor && product) {
        size_t len = strlen(vendor) + strlen(product) + 2; // +2 for space and null terminator
        result = (char*)malloc(len);
        if (result) {
            snprintf(result, len, "%s %s", vendor, product);
        }
    }

    dc_descriptor_free(descriptor);
    return result;
}

/*--------------------------------------------------------------------
 * Helper function to open BLE device with stored or identified configuration
 *------------------------------------------------------------------*/
dc_status_t open_ble_device_with_identification(device_data_t **out_data,
    const char *name, const char *address,
    dc_family_t stored_family, unsigned int stored_model)
{
    device_data_t *data = (device_data_t*)calloc(1, sizeof(device_data_t));
    if (!data) return DC_STATUS_NOMEMORY;
    
    dc_family_t family;
    unsigned int model;
    dc_status_t rc;
    
    // Try stored configuration first if provided
    if (stored_family != DC_FAMILY_NULL && stored_model != 0) {
        rc = open_ble_device(data, address, stored_family, stored_model);
        if (rc == DC_STATUS_SUCCESS) {
            *out_data = data;
            return DC_STATUS_SUCCESS;
        }
    }
    
    // Fall back to identification if stored config failed or wasn't provided
    rc = get_device_info_from_name(name, &family, &model);
    if (rc != DC_STATUS_SUCCESS) {
        free(data);
        return rc;
    }
    
    rc = open_ble_device(data, address, family, model);
    if (rc != DC_STATUS_SUCCESS) {
        free(data);
        return rc;
    }
    
    *out_data = data;
    return DC_STATUS_SUCCESS;
}