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
 */
dc_status_t find_descriptor_by_name(dc_descriptor_t **out_descriptor, const char *name);

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
 * Gets all alternative models for a device name within the same family
 * @param name: Device name to match
 * @param family: Device family to search within
 * @param models: Output array for model numbers (caller must free)
 * @param model_count: Output parameter for number of models found
 * @param max_models: Maximum number of models to return
 * @return DC_STATUS_SUCCESS on success
 */
dc_status_t get_alternative_models_for_name(const char *name, dc_family_t family,
    unsigned int *models, unsigned int *model_count, unsigned int max_models);

/**
 * Event callback for device events (used internally)
 */
void event_cb(dc_device_t *device, dc_event_type_t event, const void *data, void *userdata);

/**
 * Gets formatted display name for a device
 * @param name: Device name to match
 * @return Formatted string "Vendor Product" (caller must free) or NULL
 */
char* get_formatted_device_name(const char *name);

/**
 * Opens a BLE device connection
 * @param data: Device data structure to initialize
 * @param devaddr: BLE device address/UUID
 * @param family: Device family
 * @param model: Device model
 * @return DC_STATUS_SUCCESS on success
 */
dc_status_t open_ble_device(device_data_t *data, const char *devaddr, 
    dc_family_t family, unsigned int model);

/**
 * Reopens a device with a different model, reusing the existing BLE connection
 * @param data: Device data structure (must have valid context and iostream)
 * @param family: Device family
 * @param model: New model number to try
 * @return DC_STATUS_SUCCESS on success
 */
dc_status_t reopen_ble_device_with_model(device_data_t *data, 
    dc_family_t family, unsigned int model);

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
 * Gets pointer to device data structure
 * @return Pointer to device_data_t or NULL
 */
device_data_t* get_device_data_pointer(void);

/**
 * Toggle verbose BLE/protocol debug logging (off by default). When enabled,
 * the libdivecomputer context runs at DC_LOGLEVEL_DEBUG (surfacing protocol
 * hexdumps) and extra C-side traces print. Enable only when diagnosing a
 * device; leave off for normal use.
 * @param enabled: non-zero to enable, 0 to disable
 */
void set_ble_debug_logging(int enabled);

#ifdef __cplusplus
}
#endif

#endif /* CONFIGUREDC_H */ 