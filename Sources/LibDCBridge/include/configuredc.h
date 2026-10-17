#ifndef CONFIGUREDC_H
#define CONFIGUREDC_H

/*--------------------------------------------------------------------
 * Includes
 *------------------------------------------------------------------*/
#include <stdbool.h>
#include <stdint.h>
#include <libdivecomputer/common.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/context.h>
#include <libdivecomputer/descriptor.h>
#include <libdivecomputer/device.h>
#include <libdivecomputer/parser.h>
#include <libdivecomputer/iterator.h>

#ifdef __cplusplus
extern "C" {
#endif

/*--------------------------------------------------------------------
 * Type Definitions
 *------------------------------------------------------------------*/
// Forward declare opaque types
typedef struct dc_device_t dc_device_t;
typedef struct dc_event_devinfo_t dc_event_devinfo_t;
typedef struct dc_event_progress_t dc_event_progress_t;

typedef struct {
    dc_device_t *device;
    dc_context_t *context;
    dc_iostream_t *iostream;
    dc_descriptor_t *descriptor;
    
    // device info
    int have_devinfo;
    dc_event_devinfo_t devinfo;
    int have_progress;
    dc_event_progress_t progress;
    int have_clock;
    dc_event_clock_t clock;
    
    // fingerprints
    unsigned char *fingerprint;  
    unsigned int fsize;         
    void *fingerprint_context;  // Context to pass to lookup function
    unsigned char *(*lookup_fingerprint)(void *context, const char *device_type, const char *serial, size_t *size);
    
    // device identification
    const char *model;     // Model string (from descriptor)
    uint32_t fdeviceid;   // Device ID associated with fingerprint
    uint32_t fdiveid;     // Dive ID associated with fingerprint
} device_data_t;

typedef void (*dc_sample_callback_t)(dc_sample_type_t type, 
                                   const dc_sample_value_t *value, 
                                   void *userdata);

typedef int (*dc_dive_callback_t)(const unsigned char *data, 
                                unsigned int size, 
                                const unsigned char *fingerprint, 
                                unsigned int fsize,
                                void *userdata);

typedef void (*dc_event_callback_t)(dc_device_t *device, 
                                  dc_event_type_t event, 
                                  const void *data, 
                                  void *userdata);

/*--------------------------------------------------------------------
 * Device Descriptor Functions
 *------------------------------------------------------------------*/
/**
 * Finds a device descriptor by family and model
 * @param out_descriptor: Output parameter for found descriptor
 * @param family: Device family to match
 * @param model: Device model to match
 * @return DC_STATUS_SUCCESS on success
 * @note Caller must free the returned descriptor
 */
dc_status_t find_descriptor_by_model(dc_descriptor_t **out_descriptor, 
    dc_family_t family, unsigned int model);

/**
 * Finds a device descriptor by BLE device name
 * @param out_descriptor: Output parameter for found descriptor
 * @param name: Device name to match
 * @return DC_STATUS_SUCCESS on success
 * @note Caller must free the returned descriptor
 * @note Same as find_descriptor_by_name_transport(out_descriptor, name, DC_TRANSPORT_BLE)
 */
dc_status_t find_descriptor_by_name(dc_descriptor_t **out_descriptor, const char *name);

/**
 * Finds a device descriptor by name among the descriptors that support one transport
 * @param out_descriptor: Output parameter for found descriptor
 * @param name: Device name to match
 * @param transport: A single DC_TRANSPORT_* value
 * @return DC_STATUS_SUCCESS on success, DC_STATUS_UNSUPPORTED if nothing matches,
 *         DC_STATUS_INVALIDARGS for a NULL argument, DC_TRANSPORT_NONE or several transports
 * @note DC_TRANSPORT_BLE matches advertised names exactly as find_descriptor_by_name does.
 *       Every other transport matches "Vendor Product" exactly, first in descriptor table
 *       order; DC_TRANSPORT_BLUETOOTH and DC_TRANSPORT_IRDA then fall back to
 *       libdivecomputer's name filter for that transport.
 * @note Caller must free the returned descriptor
 */
dc_status_t find_descriptor_by_name_transport(dc_descriptor_t **out_descriptor,
    const char *name, dc_transport_t transport);

/*--------------------------------------------------------------------
 * BLE Device Functions
 *------------------------------------------------------------------*/
/**
 * Gets device family and model information from BLE name
 * @param name: Device name to identify
 * @param family: Output parameter for device family
 * @param model: Output parameter for device model
 * @return DC_STATUS_SUCCESS on success
 */
dc_status_t get_device_info_from_name(const char *name, dc_family_t *family, unsigned int *model);

/**
 * Gets formatted display name for a device
 * @param name: Device name to match
 * @return Formatted string "Vendor Product" (caller must free) or NULL
 */
char* get_formatted_device_name(const char *name);

/** dc_device_open attempts open_ble_device makes on one BLE link, and the wait between them */
#define LIBDC_BLE_OPEN_ATTEMPTS 5
#define LIBDC_BLE_OPEN_RETRY_MS 3000

/**
 * Opens a BLE device connection
 * @param data: Device data structure to initialize
 * @param devaddr: BLE device address/UUID
 * @param family: Device family
 * @param model: Device model
 * @return DC_STATUS_SUCCESS on success
 * @note Connects only once the descriptor resolves, then opens through the same path as
 *       open_device_on_iostream with LIBDC_BLE_OPEN_ATTEMPTS / LIBDC_BLE_OPEN_RETRY_MS
 */
dc_status_t open_ble_device(device_data_t *data, const char *devaddr, 
    dc_family_t family, unsigned int model);

/**
 * Opens a device on an iostream the caller has already opened
 * @param data: Device data structure. data->context must be the context iostream was
 *              opened on; every other field is reset
 * @param iostream: The open iostream
 * @param family: Device family
 * @param model: Device model
 * @param attempts: dc_device_open attempts on this iostream (at least 1)
 * @param retry_ms: Wait between attempts, in milliseconds
 * @return DC_STATUS_SUCCESS on success, DC_STATUS_INVALIDARGS for a NULL data, context
 *         or iostream or zero attempts, else the descriptor lookup's or last attempt's status
 * @note Takes ownership of data->context and iostream on every path. On success data holds
 *       them with the device, descriptor and "Vendor Product" model string, and subscribes
 *       to DEVINFO, PROGRESS and CLOCK events, recorded in devinfo, progress and clock (each
 *       with its have_ flag). On failure both are released and data is zeroed.
 * @note Sets the bridge's log callback and level (set_ble_debug_logging) on data->context.
 */
dc_status_t open_device_on_iostream(device_data_t *data, dc_iostream_t *iostream,
    dc_family_t family, unsigned int model, unsigned int attempts, unsigned int retry_ms);

/**
 * Installs (or, with a NULL callback, clears) the cancel check on an open device
 * @param data: Device data structure with an open device
 * @param callback: Returns non-zero to cancel; libdivecomputer polls it between transfers
 * @param userdata: Passed to callback
 * @return DC_STATUS_SUCCESS on success, DC_STATUS_INVALIDARGS if no device is open
 */
dc_status_t libdc_set_cancel(device_data_t *data, dc_cancel_callback_t callback, void *userdata);

/**
 * Releases everything a successful open left in data: the device, iostream, context,
 * descriptor, model string and fingerprint buffer
 * @param data: Device data structure; NULL is ignored. Every pointer field is NULL afterwards
 * @note Clear any cancel callback (libdc_set_cancel) whose userdata dies with the caller first
 */
void libdc_close_device_data(device_data_t *data);

/**
 * Opens a BLE device with automatic identification
 * @param out_data: Output parameter for device data
 * @param name: Device name
 * @param address: BLE device address
 * @param stored_family: Optional stored family (DC_FAMILY_NULL if none)
 * @param stored_model: Optional stored model (0 if none)
 * @return DC_STATUS_SUCCESS on success
 */
dc_status_t open_ble_device_with_identification(device_data_t **out_data, 
    const char *name, const char *address,
    dc_family_t stored_family, unsigned int stored_model);

/*--------------------------------------------------------------------
 * Parser Functions
 *------------------------------------------------------------------*/
/**
 * Creates a parser for dive data
 * @param parser: Output parameter for created parser
 * @param context: Dive computer context
 * @param family: Device family
 * @param model: Device model
 * @param data: Raw dive data
 * @param size: Size of raw data
 * @return DC_STATUS_SUCCESS on success
 */
dc_status_t create_parser_for_device(dc_parser_t **parser, dc_context_t *context,
    dc_family_t family, unsigned int model, const unsigned char *data, size_t size);

/*--------------------------------------------------------------------
 * Utility Functions
 *------------------------------------------------------------------*/
/**
 * Toggle verbose BLE/protocol debug logging (off by default). When enabled,
 * the libdivecomputer context runs at DC_LOGLEVEL_DEBUG (surfacing protocol
 * hexdumps) and extra C-side traces print. Enable only when diagnosing a
 * device; leave off for normal use.
 * @param enabled: non-zero to enable, 0 to disable
 */
void set_ble_debug_logging(int enabled);

/**
 * Whether the serial driver can set non-standard baud rates (IOSSIOSPEED).
 * True on macOS; false on iOS, where a non-standard rate returns DC_STATUS_UNSUPPORTED.
 */
bool libdc_has_custom_baud(void);

/**
 * Cable transports (DC_TRANSPORT_* bits) this platform can reach: SERIAL | USBHID on macOS,
 * none on iOS. Use this rather than dc_context_get_transports, which always reports SERIAL.
 */
unsigned int libdc_cable_transports(void);

#ifdef __cplusplus
}
#endif

#endif /* CONFIGUREDC_H */ 