#import "BLEBridge.h"
#import <Foundation/Foundation.h>
#import "BLETest-Swift.h"

static CoreBluetoothManager *bleManager = nil;

void initializeBLEManager(void) {
    bleManager = CoreBluetoothManager.shared;
}

ble_object_t* createBLEObject(void) {
    ble_object_t* obj = malloc(sizeof(ble_object_t));
    obj->manager = (__bridge void *)bleManager;
    return obj;
}

void freeBLEObject(ble_object_t* obj) {
    if (obj) {
        free(obj);
    }
}

bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress) {
    if (!io || !deviceAddress) {
        NSLog(@"Invalid parameters passed to connectToBLEDevice");
        return false;
    }
    
    CoreBluetoothManager *manager = (__bridge CoreBluetoothManager*)io->manager;
    NSString *address = [NSString stringWithUTF8String:deviceAddress];
    
    bool success = [manager connectToDevice:address];
    if (!success) {
        NSLog(@"Failed to connect to device");
        return false;
    }
    
    // Wait for initial connection
    [NSThread sleepForTimeInterval:1.0];
    
    // Discover services
    success = [manager discoverServices];
    if (!success) {
        NSLog(@"Service discovery failed");
        [manager close];
        return false;
    }
    
    // Enable notifications
    success = [manager enableNotifications];
    if (!success) {
        NSLog(@"Failed to enable notifications");
        [manager close];
        return false;
    }
    
    return true;
}

bool discoverServices(ble_object_t *io) {
    CoreBluetoothManager *manager = (__bridge CoreBluetoothManager*)io->manager;
    return [manager discoverServices];
}

bool enableNotifications(ble_object_t *io) {
    CoreBluetoothManager *manager = (__bridge CoreBluetoothManager*)io->manager;
    return [manager enableNotifications];
}

dc_status_t ble_set_timeout(ble_object_t *io, int timeout) {
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data, size_t size) {
    return DC_STATUS_UNSUPPORTED;
}

dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds) {
    [NSThread sleepForTimeInterval:milliseconds / 1000.0];
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_read(ble_object_t *io, void *data, size_t size, size_t *actual) {
    CoreBluetoothManager *manager = (__bridge CoreBluetoothManager*)io->manager;
    NSData *receivedData = [manager readData:(int)size];
    
    if (receivedData) {
        // Only copy up to the requested size
        size_t copySize = MIN(receivedData.length, size);
        memcpy(data, receivedData.bytes, copySize);
        *actual = copySize;
        return DC_STATUS_SUCCESS;
    } else {
        *actual = 0;
        return DC_STATUS_IO;
    }
}

dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual) {
    CoreBluetoothManager *manager = (__bridge CoreBluetoothManager*)io->manager;
    NSData *nsData = [NSData dataWithBytes:data length:size];
    
    if ([manager writeData:nsData]) {
        *actual = size;
        return DC_STATUS_SUCCESS;
    } else {
        *actual = 0;
        return DC_STATUS_IO;
    }
}

dc_status_t ble_close(ble_object_t *io) {
    CoreBluetoothManager *manager = (__bridge CoreBluetoothManager*)io->manager;
    [manager close];
    return DC_STATUS_SUCCESS;
}
