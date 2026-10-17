#import "USBBridge.h"

#if TARGET_OS_OSX
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#include <time.h>
#include <libdivecomputer/custom.h>
#include <libdivecomputer/ioctl.h>

#if !__has_feature(objc_arc)
#error "USBBridge.m hands the stream to libdivecomputer with ARC bridge casts"
#endif

// usb.c measures the setup as sizeof(control), a pointer: the struct's own 8 bytes on every 64-bit Mac.
_Static_assert(sizeof(dc_usb_control_t) == 8, "dc_usb_control_t is the 8-byte setup usb.c reads ahead of the data stage");

static const uint32_t LIBDC_USB_CANCEL_CHECK_MS = 50;

static uint64_t libdc_usb_now_ns(void)
{
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

// What libusb's darwin backend makes of an IOReturn, then usb.c's syserror.
static dc_status_t libdc_usb_status(IOReturn result)
{
    switch (result) {
    case kIOReturnSuccess:
    case kIOReturnUnderrun:
        return DC_STATUS_SUCCESS;
    case kIOUSBTransactionTimeout:
    case kIOReturnTimeout:
        return DC_STATUS_TIMEOUT;
    case kIOReturnNoDevice:
    case kIOReturnNotOpen:
    case kIOReturnNotAttached:
        return DC_STATUS_NODEVICE;
    case kIOReturnExclusiveAccess:
    case kIOReturnNotPermitted:
    case kIOReturnNotPrivileged:
        return DC_STATUS_NOACCESS;
    case kIOReturnBadArgument:
        return DC_STATUS_INVALIDARGS;
    case kIOReturnNoMemory:
    case kIOReturnNoResources:
        return DC_STATUS_NOMEMORY;
    default:
        return DC_STATUS_IO;
    }
}

static BOOL libdc_usb_succeeded(IOReturn result)
{
    return result == kIOReturnSuccess || result == kIOReturnUnderrun;
}

@interface LibDCUSBStream ()
- (dc_status_t)setTimeoutValue:(int)timeout;
- (dc_status_t)readInto:(unsigned char *)data size:(size_t)size actual:(size_t *)actual;
- (dc_status_t)writeFrom:(const unsigned char *)data size:(size_t)size actual:(size_t *)actual;
- (dc_status_t)controlWithBuffer:(unsigned char *)data size:(size_t)size;
- (void)closeDevice;
@end

static dc_status_t libdc_usb_set_timeout(void *userdata, int timeout)
{
    return [(__bridge LibDCUSBStream *)userdata setTimeoutValue:timeout];
}

// usb.c's vtable has no entry for these, and dc_iostream_* answers SUCCESS for a missing one.
static dc_status_t libdc_usb_set_break(void *userdata, unsigned int value) { return DC_STATUS_SUCCESS; }
static dc_status_t libdc_usb_set_dtr(void *userdata, unsigned int value) { return DC_STATUS_SUCCESS; }
static dc_status_t libdc_usb_set_rts(void *userdata, unsigned int value) { return DC_STATUS_SUCCESS; }
static dc_status_t libdc_usb_configure(void *userdata, unsigned int baudrate, unsigned int databits, dc_parity_t parity,
    dc_stopbits_t stopbits, dc_flowcontrol_t flowcontrol) { return DC_STATUS_SUCCESS; }
static dc_status_t libdc_usb_flush(void *userdata) { return DC_STATUS_SUCCESS; }
static dc_status_t libdc_usb_purge(void *userdata, dc_direction_t direction) { return DC_STATUS_SUCCESS; }
// No sleep entry either, so upstream returns at once instead of sleeping.
static dc_status_t libdc_usb_sleep(void *userdata, unsigned int milliseconds) { return DC_STATUS_SUCCESS; }

static dc_status_t libdc_usb_get_lines(void *userdata, unsigned int *value)
{
    if (value) *value = 0;
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_usb_get_available(void *userdata, size_t *value)
{
    if (value) *value = 0;
    return DC_STATUS_SUCCESS;
}

static dc_status_t libdc_usb_poll(void *userdata, int timeout)
{
    return DC_STATUS_UNSUPPORTED;
}

static dc_status_t libdc_usb_read(void *userdata, void *data, size_t size, size_t *actual)
{
    return [(__bridge LibDCUSBStream *)userdata readInto:data size:size actual:actual];
}

static dc_status_t libdc_usb_write(void *userdata, const void *data, size_t size, size_t *actual)
{
    return [(__bridge LibDCUSBStream *)userdata writeFrom:data size:size actual:actual];
}

static dc_status_t libdc_usb_ioctl(void *userdata, unsigned int request, void *data, size_t size)
{
    switch (request) {
    case DC_IOCTL_USB_CONTROL_READ:
    case DC_IOCTL_USB_CONTROL_WRITE:
        return [(__bridge LibDCUSBStream *)userdata controlWithBuffer:data size:size];
    default:
        return DC_STATUS_UNSUPPORTED;
    }
}

static dc_status_t libdc_usb_close(void *userdata)
{
    LibDCUSBStream *stream = (__bridge_transfer LibDCUSBStream *)userdata;
    [stream closeDevice];
    return DC_STATUS_SUCCESS;
}

// All 15 set: custom.c answers SUCCESS for a NULL callback without calling anything.
static const dc_custom_cbs_t libdc_usb_callbacks = {
    .set_timeout = libdc_usb_set_timeout,
    .set_break = libdc_usb_set_break,
    .set_dtr = libdc_usb_set_dtr,
    .set_rts = libdc_usb_set_rts,
    .get_lines = libdc_usb_get_lines,
    .get_available = libdc_usb_get_available,
    .configure = libdc_usb_configure,
    .poll = libdc_usb_poll,
    .read = libdc_usb_read,
    .write = libdc_usb_write,
    .ioctl = libdc_usb_ioctl,
    .flush = libdc_usb_flush,
    .purge = libdc_usb_purge,
    .sleep = libdc_usb_sleep,
    .close = libdc_usb_close,
};

@implementation LibDCUSBStream {
    id<LibDCUSBDevice> _device;
    uint8_t _endpointIn;
    uint8_t _endpointOut;
    uint16_t _packetIn;
    // usb.c's: 0 waits for ever, and it starts there.
    unsigned int _timeout;
    NSLock *_lock;
    BOOL _transferring;
    BOOL _abortSent;
    BOOL _opened;
    BOOL _closedFlag;
    BOOL _removedFlag;
    dispatch_queue_t _watchQueue;
    dispatch_source_t _watch;
}

@synthesize cancelCheck = _cancelCheck;
@synthesize removalHandler = _removalHandler;

+ (uint32_t)cancelCheckMilliseconds
{
    return LIBDC_USB_CANCEL_CHECK_MS;
}

- (instancetype)initWithDevice:(id<LibDCUSBDevice>)device endpointIn:(uint8_t)endpointIn endpointOut:(uint8_t)endpointOut
{
    if ((self = [super init])) {
        _device = device;
        _endpointIn = endpointIn;
        _endpointOut = endpointOut;
        _packetIn = [device maxPacketSizeForEndpoint:endpointIn];
        _lock = [[NSLock alloc] init];
        _watchQueue = dispatch_queue_create("com.libdcswift.usb.cancel", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    if (_watch) dispatch_source_cancel(_watch);
}

- (BOOL)isRemoved
{
    [_lock lock];
    BOOL removed = _removedFlag;
    [_lock unlock];
    return removed;
}

- (BOOL)isClosed
{
    [_lock lock];
    BOOL closed = _closedFlag;
    [_lock unlock];
    return closed;
}

- (BOOL)cancelRequested
{
    BOOL (^check)(void) = self.cancelCheck;
    return check != nil && check();
}

- (dc_status_t)openIOStream:(dc_iostream_t **)iostream context:(dc_context_t *)context
{
    *iostream = NULL;
    [_lock lock];
    BOOL fresh = !_opened && !_closedFlag;
    _opened = YES;
    [_lock unlock];
    if (!fresh) return DC_STATUS_INVALIDARGS;

    _watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _watchQueue);
    __weak LibDCUSBStream *weakSelf = self;
    dispatch_source_set_event_handler(_watch, ^{ [weakSelf watchTick]; });
    dispatch_source_set_timer(_watch, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(_watch);

    void *userdata = (__bridge_retained void *)self;
    dc_status_t status = dc_custom_open(iostream, context, DC_TRANSPORT_USB, &libdc_usb_callbacks, userdata);
    if (status != DC_STATUS_SUCCESS) {
        *iostream = NULL;
        LibDCUSBStream *owned = (__bridge_transfer LibDCUSBStream *)userdata;
        [owned closeDevice];
    }
    return status;
}

// MARK: - Cancel watch

// Armed only while a transfer runs; it aborts that transfer once when the cancel check turns true.
- (void)beginTransfer
{
    [_lock lock];
    _transferring = YES;
    _abortSent = NO;
    [_lock unlock];
    uint64_t interval = (uint64_t)LIBDC_USB_CANCEL_CHECK_MS * NSEC_PER_MSEC;
    dispatch_source_set_timer(_watch, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, NSEC_PER_MSEC);
}

- (void)endTransfer
{
    dispatch_source_set_timer(_watch, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    [_lock lock];
    _transferring = NO;
    [_lock unlock];
}

- (void)watchTick
{
    [_lock lock];
    BOOL armed = _transferring && !_abortSent && !_closedFlag;
    [_lock unlock];
    if (!armed || ![self cancelRequested]) return;
    [_lock lock];
    if (_transferring && !_abortSent && !_closedFlag) {
        _abortSent = YES;
        [_device abortTransfers];
    }
    [_lock unlock];
}

// MARK: - Operations

- (dc_status_t)setTimeoutValue:(int)timeout
{
    if (timeout < 0) {
        _timeout = 0;
    } else if (timeout == 0) {
        return DC_STATUS_UNSUPPORTED;
    } else {
        _timeout = (unsigned int)timeout;
    }
    return DC_STATUS_SUCCESS;
}

- (dc_status_t)failure:(IOReturn)result endpoint:(uint8_t)endpoint
{
    if ([self cancelRequested]) return DC_STATUS_CANCELLED;
    dc_status_t status = libdc_usb_status(result);
    if (status == DC_STATUS_TIMEOUT) {
        // IOUSBLib leaves the data toggle to be put back in step after a timed-out bulk transfer.
        if (endpoint != 0) [_device clearStallOnEndpoint:endpoint];
        return status;
    }
    if (![_device isAttached]) {
        [_lock lock];
        BOOL first = !_removedFlag;
        _removedFlag = YES;
        [_lock unlock];
        void (^handler)(void) = self.removalHandler;
        if (first && handler) handler();
        return DC_STATUS_NODEVICE;
    }
    return status;
}

// One max-size packet per request: a timed-out ReadPipeTO reports no count, so a whole-size request would lose what came first.
- (dc_status_t)readInto:(unsigned char *)data size:(size_t)size actual:(size_t *)actual
{
    if (actual) *actual = 0;
    if ([self cancelRequested]) return DC_STATUS_CANCELLED;
    if (size == 0) return DC_STATUS_SUCCESS;
    const size_t packet = _packetIn > 0 ? _packetIn : 64;
    const uint64_t deadline = _timeout ? libdc_usb_now_ns() + (uint64_t)_timeout * NSEC_PER_MSEC : 0;
    dc_status_t status = DC_STATUS_SUCCESS;
    size_t done = 0;
    [self beginTransfer];
    while (done < size) {
        uint32_t wait = 0;
        if (deadline) {
            uint64_t now = libdc_usb_now_ns();
            if (now >= deadline) {
                status = DC_STATUS_TIMEOUT;
                break;
            }
            // Rounded up: 0 would wait for ever.
            wait = (uint32_t)MIN((deadline - now + NSEC_PER_MSEC - 1) / NSEC_PER_MSEC, (uint64_t)UINT32_MAX);
        }
        const uint32_t want = (uint32_t)MIN(size - done, packet);
        uint32_t got = 0;
        IOReturn result = [_device transferOnEndpoint:_endpointIn data:data + done length:want actual:&got timeout:wait];
        if (!libdc_usb_succeeded(result)) {
            status = [self failure:result endpoint:_endpointIn];
            break;
        }
        done += MIN(got, want);
        // A short packet ends a bulk transfer.
        if (got < want) break;
        if (done < size && [self cancelRequested]) {
            status = DC_STATUS_CANCELLED;
            break;
        }
    }
    [self endTransfer];
    if (actual) *actual = done;
    return status;
}

- (dc_status_t)writeFrom:(const unsigned char *)data size:(size_t)size actual:(size_t *)actual
{
    if (actual) *actual = 0;
    if ([self cancelRequested]) return DC_STATUS_CANCELLED;
    if (size > UINT32_MAX) return DC_STATUS_INVALIDARGS;
    uint32_t written = 0;
    [self beginTransfer];
    IOReturn result = [_device transferOnEndpoint:_endpointOut data:(void *)data length:(uint32_t)size actual:&written timeout:0];
    [self endTransfer];
    if (!libdc_usb_succeeded(result)) return [self failure:result endpoint:_endpointOut];
    if (actual) *actual = MIN((size_t)written, size);
    return DC_STATUS_SUCCESS;
}

// usb.c's dc_usb_ioctl_control; a transfer that moved its data stage is SUCCESS, where usb.c takes libusb's byte count for an error.
- (dc_status_t)controlWithBuffer:(unsigned char *)data size:(size_t)size
{
    const size_t header = sizeof(dc_usb_control_t);
    if (data == NULL || size < header) return DC_STATUS_INVALIDARGS;
    dc_usb_control_t setup;
    memcpy(&setup, data, header);
    if (setup.wLength > size - header) return DC_STATUS_INVALIDARGS;
    if ([self cancelRequested]) return DC_STATUS_CANCELLED;
    [self beginTransfer];
    IOReturn result = [_device controlTransfer:&setup data:(setup.wLength > 0 ? data + header : NULL) timeout:_timeout];
    [self endTransfer];
    if (!libdc_usb_succeeded(result)) return [self failure:result endpoint:0];
    return DC_STATUS_SUCCESS;
}

- (void)closeDevice
{
    if (_watch) {
        dispatch_source_cancel(_watch);
        // Waits out a tick already running, so nothing aborts a closed device.
        dispatch_sync(_watchQueue, ^{});
    }
    [_lock lock];
    BOOL first = !_closedFlag;
    _closedFlag = YES;
    [_lock unlock];
    if (first) [_device close];
}

@end

// MARK: - IOUSBLib device

static void *libdc_usb_plugin(io_service_t service, CFUUIDRef type, CFUUIDRef interfaceID, IOReturn *result)
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service, type, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != kIOReturnSuccess || plugin == NULL) {
        *result = kr != kIOReturnSuccess ? kr : kIOReturnNoResources;
        return NULL;
    }
    void *interface = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), &interface);
    IODestroyPlugInInterface(plugin);
    if (hr != S_OK || interface == NULL) {
        *result = kIOReturnUnsupported;
        return NULL;
    }
    return interface;
}

static BOOL libdc_usb_interface_number(io_service_t service, uint8_t *number)
{
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
    if (value == NULL) return NO;
    int parsed = -1;
    BOOL ok = CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue(value, kCFNumberIntType, &parsed);
    CFRelease(value);
    if (!ok || parsed < 0 || parsed > UINT8_MAX) return NO;
    *number = (uint8_t)parsed;
    return YES;
}

@implementation LibDCIOUSBDevice {
    uint64_t _registryID;
    uint8_t _endpointIn;
    uint8_t _endpointOut;
    IOUSBDeviceInterface500 **_device;
    IOUSBInterfaceInterface500 **_interface;
    BOOL _deviceOpen;
    BOOL _interfaceOpen;
    BOOL _closed;
    UInt8 _pipeIn;
    UInt8 _pipeOut;
    uint16_t _packetIn;
    uint16_t _packetOut;
    NSLock *_lock;
}

+ (instancetype)openWithRegistryID:(uint64_t)registryID interfaceNumber:(uint8_t)interfaceNumber
                        endpointIn:(uint8_t)endpointIn endpointOut:(uint8_t)endpointOut result:(int32_t *)result
{
    LibDCIOUSBDevice *device = [[self alloc] initWithRegistryID:registryID endpointIn:endpointIn endpointOut:endpointOut];
    IOReturn kr = [device openInterface:interfaceNumber];
    *result = kr;
    if (kr != kIOReturnSuccess) {
        [device close];
        return nil;
    }
    return device;
}

- (instancetype)initWithRegistryID:(uint64_t)registryID endpointIn:(uint8_t)endpointIn endpointOut:(uint8_t)endpointOut
{
    if ((self = [super init])) {
        _registryID = registryID;
        _endpointIn = endpointIn;
        _endpointOut = endpointOut;
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

- (IOReturn)openInterface:(uint8_t)interfaceNumber
{
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(_registryID);
    if (matching == NULL) return kIOReturnNoMemory;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) return kIOReturnNoDevice;
    IOReturn kr = kIOReturnSuccess;
    _device = libdc_usb_plugin(service, kIOUSBDeviceUserClientTypeID, kIOUSBDeviceInterfaceID500, &kr);
    IOObjectRelease(service);
    if (_device == NULL) return kr;

    kr = (*_device)->USBDeviceOpenSeize(_device);
    // As libusb does, carry on without the device when another client has it: its interfaces may still be free.
    if (kr == kIOReturnSuccess) {
        _deviceOpen = YES;
    } else if (kr != kIOReturnExclusiveAccess) {
        return kr;
    }

    // A vendor-class device can arrive unconfigured, with no interfaces until a configuration is set.
    UInt8 configuration = 0;
    if (_deviceOpen && (*_device)->GetConfiguration(_device, &configuration) == kIOReturnSuccess && configuration == 0) {
        IOUSBConfigurationDescriptorPtr descriptor = NULL;
        kr = (*_device)->GetConfigurationDescriptorPtr(_device, 0, &descriptor);
        if (kr != kIOReturnSuccess) return kr;
        if (descriptor == NULL) return kIOUSBConfigNotFound;
        kr = (*_device)->SetConfiguration(_device, descriptor->bConfigurationValue);
        if (kr != kIOReturnSuccess) return kr;
    }

    io_service_t interfaceService = [self interfaceService:interfaceNumber];
    if (interfaceService == IO_OBJECT_NULL) return kIOUSBInterfaceNotFound;
    _interface = libdc_usb_plugin(interfaceService, kIOUSBInterfaceUserClientTypeID, kIOUSBInterfaceInterfaceID500, &kr);
    IOObjectRelease(interfaceService);
    if (_interface == NULL) return kr;
    kr = (*_interface)->USBInterfaceOpen(_interface);
    if (kr != kIOReturnSuccess) return kr;
    _interfaceOpen = YES;
    return [self findPipes];
}

- (io_service_t)interfaceService:(uint8_t)interfaceNumber
{
    IOUSBFindInterfaceRequest request = {
        .bInterfaceClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceSubClass = kIOUSBFindInterfaceDontCare,
        .bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare,
    };
    io_iterator_t iterator = IO_OBJECT_NULL;
    if ((*_device)->CreateInterfaceIterator(_device, &request, &iterator) != kIOReturnSuccess) return IO_OBJECT_NULL;
    io_service_t found = IO_OBJECT_NULL;
    io_service_t next;
    while ((next = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint8_t number = 0;
        if (found == IO_OBJECT_NULL && libdc_usb_interface_number(next, &number) && number == interfaceNumber) {
            found = next;
        } else {
            IOObjectRelease(next);
        }
    }
    IOObjectRelease(iterator);
    return found;
}

- (IOReturn)findPipes
{
    UInt8 count = 0;
    IOReturn kr = (*_interface)->GetNumEndpoints(_interface, &count);
    if (kr != kIOReturnSuccess) return kr;
    for (unsigned int pipe = 1; pipe <= count; pipe++) {
        UInt8 direction = 0, number = 0, type = 0, interval = 0;
        UInt16 maxPacket = 0;
        if ((*_interface)->GetPipeProperties(_interface, (UInt8)pipe, &direction, &number, &type, &maxPacket, &interval) != kIOReturnSuccess
            || type != kUSBBulk) {
            continue;
        }
        const uint8_t address = (uint8_t)(number | (direction == kUSBIn ? 0x80 : 0x00));
        if (address == _endpointIn && _pipeIn == 0) {
            _pipeIn = (UInt8)pipe;
            _packetIn = maxPacket;
        } else if (address == _endpointOut && _pipeOut == 0) {
            _pipeOut = (UInt8)pipe;
            _packetOut = maxPacket;
        }
    }
    return _pipeIn != 0 && _pipeOut != 0 ? kIOReturnSuccess : kIOUSBEndpointNotFound;
}

- (uint16_t)maxPacketSizeForEndpoint:(uint8_t)endpoint
{
    if (endpoint == _endpointIn) return _packetIn;
    if (endpoint == _endpointOut) return _packetOut;
    return 0;
}

- (int32_t)transferOnEndpoint:(uint8_t)endpoint data:(void *)data length:(uint32_t)length actual:(uint32_t *)actual
                      timeout:(uint32_t)timeout
{
    *actual = 0;
    if (_interface == NULL || !_interfaceOpen) return kIOReturnNotOpen;
    IOReturn kr;
    if (endpoint & 0x80) {
        if (endpoint != _endpointIn) return kIOUSBEndpointNotFound;
        UInt32 size = length;
        kr = timeout ? (*_interface)->ReadPipeTO(_interface, _pipeIn, data, &size, timeout, timeout)
                     : (*_interface)->ReadPipe(_interface, _pipeIn, data, &size);
        if (libdc_usb_succeeded(kr)) *actual = MIN(size, length);
    } else {
        if (endpoint != _endpointOut) return kIOUSBEndpointNotFound;
        kr = timeout ? (*_interface)->WritePipeTO(_interface, _pipeOut, data, length, timeout, timeout)
                     : (*_interface)->WritePipe(_interface, _pipeOut, data, length);
        if (libdc_usb_succeeded(kr)) *actual = length;
    }
    return kr;
}

- (int32_t)controlTransfer:(const dc_usb_control_t *)setup data:(void *)data timeout:(uint32_t)timeout
{
    if (_device == NULL) return kIOReturnNotOpen;
    IOUSBDevRequestTO request = {
        .bmRequestType = setup->bmRequestType,
        .bRequest = setup->bRequest,
        .wValue = setup->wValue,
        .wIndex = setup->wIndex,
        .wLength = setup->wLength,
        .pData = data,
        .noDataTimeout = timeout,
        .completionTimeout = timeout,
    };
    return (*_device)->DeviceRequestTO(_device, &request);
}

- (int32_t)clearStallOnEndpoint:(uint8_t)endpoint
{
    if (_interface == NULL || !_interfaceOpen) return kIOReturnNotOpen;
    UInt8 pipe = endpoint == _endpointIn ? _pipeIn : endpoint == _endpointOut ? _pipeOut : 0;
    if (pipe == 0) return kIOUSBEndpointNotFound;
    return (*_interface)->ClearPipeStallBothEnds(_interface, pipe);
}

- (void)abortTransfers
{
    [_lock lock];
    if (!_closed) {
        if (_interface != NULL && _interfaceOpen) {
            if (_pipeIn) (*_interface)->AbortPipe(_interface, _pipeIn);
            if (_pipeOut) (*_interface)->AbortPipe(_interface, _pipeOut);
        }
        if (_device != NULL) (*_device)->USBDeviceAbortPipeZero(_device);
    }
    [_lock unlock];
}

- (BOOL)isAttached
{
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(_registryID);
    if (matching == NULL) return YES;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) return NO;
    IOObjectRelease(service);
    return YES;
}

- (void)close
{
    [_lock lock];
    if (_closed) {
        [_lock unlock];
        return;
    }
    _closed = YES;
    if (_interface != NULL) {
        if (_interfaceOpen) (*_interface)->USBInterfaceClose(_interface);
        (*_interface)->Release(_interface);
        _interface = NULL;
        _interfaceOpen = NO;
    }
    if (_device != NULL) {
        if (_deviceOpen) (*_device)->USBDeviceClose(_device);
        (*_device)->Release(_device);
        _device = NULL;
        _deviceOpen = NO;
    }
    [_lock unlock];
}

@end

#endif
