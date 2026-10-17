#ifndef BLEBridge_h
#define BLEBridge_h

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __OBJC__
    #if __has_feature(modules)
        @import Foundation;
        @import CoreBluetooth;
    #else
        #import <Foundation/Foundation.h>
        #import <CoreBluetooth/CoreBluetooth.h>
    #endif
#endif

#include "libdivecomputer/common.h"
#include "libdivecomputer/iostream.h"
#include "libdivecomputer/custom.h"
#include "libdivecomputer/parser.h"
#include "configuredc.h"
#include "CoreBluetoothManagerProtocol.h"

// Array helper functions
static inline uint16_t array_uint16_le(const unsigned char array[]) {
    return array[0] | (array[1] << 8);
}

static inline uint32_t array_uint32_le(const unsigned char array[]) {
    return array[0] | (array[1] << 8) | (array[2] << 16) | (array[3] << 24);
}

static inline uint16_t array_uint16_be(const unsigned char array[]) {
    return (array[0] << 8) | array[1];
}

static inline uint32_t array_uint32_be(const unsigned char array[]) {
    return (array[0] << 24) | (array[1] << 16) | (array[2] << 8) | array[3];
}

// BLE object
typedef struct ble_object {
    void* manager;
} ble_object_t;

// BLE object functions
ble_object_t* createBLEObject(void);
void freeBLEObject(ble_object_t* obj);

// BLE operations
dc_status_t ble_set_timeout(ble_object_t *io, int timeout);
dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data, size_t size);
dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds);
dc_status_t ble_read(ble_object_t *io, void *data, size_t size, size_t *actual);
dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual);
dc_status_t ble_close(ble_object_t *io);

// The status ble_read reports for `length` bytes read; `ready` is the peripheral's ready state.
dc_status_t ble_read_status(bool cancelled, size_t length, bool ready);
// The status ble_write reports for a writeData: result (0 sent, 1 timed out, else failed).
dc_status_t ble_write_status(bool cancelled, long result);

// BLE setup functions
void initializeBLEManager(void);
bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress);
bool discoverServices(ble_object_t *io);
bool enableNotifications(ble_object_t *io);

#endif /* BLEBridge_h */
