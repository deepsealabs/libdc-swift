#ifndef CoreBluetoothManagerProtocol_h
#define CoreBluetoothManagerProtocol_h

#ifdef __OBJC__
#import <Foundation/Foundation.h>

@protocol CoreBluetoothManagerProtocol <NSObject>
+ (id)shared;
- (BOOL)connectToDevice:(NSString *)address;
- (BOOL)getPeripheralReadyState;
- (BOOL)discoverServices;
- (BOOL)enableNotifications;
// Returns 0 on success, 1 if the write timed out waiting for CoreBluetooth
// to be ready to send (transient -- e.g. a brief connection-interval
// renegotiation right as the app backgrounds; libdc-swift retries this
// internally a few times before giving up), 2 for a genuine write failure.
- (NSInteger)writeData:(NSData *)data;
- (NSData *)readDataPartial:(int)requested;
- (NSData *)readCharacteristicByUUID:(NSString *)uuid timeout:(double)seconds;
- (void)setReadTimeout:(int)milliseconds;
- (void)close;
@end

#else
// If we're compiling pure C (without Objective-C), provide an empty protocol definition
typedef void * CoreBluetoothManagerProtocol;
#endif

#endif /* CoreBluetoothManagerProtocol_h */ 