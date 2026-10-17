#ifndef USBBridge_h
#define USBBridge_h

#include <TargetConditionals.h>

#if TARGET_OS_OSX && defined(__OBJC__)
#import <Foundation/Foundation.h>
#include <libdivecomputer/iostream.h>
#include <libdivecomputer/usb.h>

NS_ASSUME_NONNULL_BEGIN

/** The IOUSBLib calls LibDCUSBStream makes on one claimed interface, returning IOReturns; tests pass fakes. */
NS_SWIFT_NAME(USBDeviceIO)
@protocol LibDCUSBDevice <NSObject>
/** The max packet size of the bulk pipe at `endpoint`. */
- (uint16_t)maxPacketSizeForEndpoint:(uint8_t)endpoint NS_SWIFT_NAME(maxPacketSize(endpoint:));
/** ReadPipeTO for an IN endpoint, else WritePipeTO, `timeout` 0 waiting for ever; `*actual` is 0 unless it succeeded. */
- (int32_t)transferOnEndpoint:(uint8_t)endpoint data:(void *)data length:(uint32_t)length actual:(uint32_t *)actual
                      timeout:(uint32_t)timeout NS_SWIFT_NAME(transfer(endpoint:data:length:actual:timeout:));
/** DeviceRequestTO on the default pipe, with `setup`'s wLength-byte data stage in `data` (NULL when wLength is 0). */
- (int32_t)controlTransfer:(const dc_usb_control_t *)setup data:(void * _Nullable)data
                   timeout:(uint32_t)timeout NS_SWIFT_NAME(control(_:data:timeout:));
/** ClearPipeStallBothEnds on the pipe at `endpoint`. */
- (int32_t)clearStallOnEndpoint:(uint8_t)endpoint NS_SWIFT_NAME(clearStall(endpoint:));
/** From any thread: a blocked transfer returns kIOReturnAborted. */
- (void)abortTransfers;
/** The device's registry entry is still there. */
@property (readonly, getter=isAttached) BOOL attached;
/** Closes the interface and the device; called once. */
- (void)close;
@end

/** libdivecomputer's USB transport, answering as usb.c's libusb build does (Docs/MACOS_USB.md), as a dc_custom_open iostream with DC_TRANSPORT_USB. */
NS_SWIFT_NAME(USBStream)
@interface LibDCUSBStream : NSObject
- (instancetype)initWithDevice:(id<LibDCUSBDevice>)device endpointIn:(uint8_t)endpointIn
                   endpointOut:(uint8_t)endpointOut NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/** The longest a blocked transfer runs between cancel checks. */
@property (class, readonly) uint32_t cancelCheckMilliseconds;
/** While it returns YES, transfers return DC_STATUS_CANCELLED, and one in progress is aborted. */
@property (atomic, copy, nullable) BOOL (^cancelCheck)(void);
/** Runs once, on the transferring thread, when a transfer fails because the device is gone. */
@property (atomic, copy, nullable) void (^removalHandler)(void);
@property (atomic, readonly, getter=isRemoved) BOOL removed;
@property (atomic, readonly, getter=isClosed) BOOL closed;

/** Opens the iostream, which holds this stream until dc_iostream_close closes the device; a failed open closes it too, and a second call is DC_STATUS_INVALIDARGS. */
- (dc_status_t)openIOStream:(dc_iostream_t * _Nullable * _Nonnull)iostream
                    context:(dc_context_t * _Nullable)context NS_SWIFT_NAME(open(_:context:));
@end

/** The live LibDCUSBDevice: interface `interfaceNumber` of the USB device with `registryID`, on IOUSBLib's 500 interfaces. */
NS_SWIFT_NAME(IOKitUSBDevice)
@interface LibDCIOUSBDevice : NSObject <LibDCUSBDevice>
/** Nil with `*result` set when it can't be opened: kIOReturnNoDevice, kIOReturnExclusiveAccess, kIOUSBInterfaceNotFound, kIOUSBEndpointNotFound, or IOKit's own. */
+ (nullable instancetype)openWithRegistryID:(uint64_t)registryID interfaceNumber:(uint8_t)interfaceNumber
                                 endpointIn:(uint8_t)endpointIn endpointOut:(uint8_t)endpointOut
                                     result:(int32_t *)result NS_SWIFT_NAME(open(registryID:interfaceNumber:endpointIn:endpointOut:result:));
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

#endif

#endif /* USBBridge_h */
