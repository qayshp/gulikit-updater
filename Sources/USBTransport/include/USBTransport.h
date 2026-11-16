#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#import "GUBOTResponse.h"

NS_ASSUME_NONNULL_BEGIN
/// Open only after AAUSBAccessory has granted this app exclusive ownership.
@interface GUUSBTransport : NSObject
/// Tags an object without retaining it, so diagnostics can identify reuse and
/// observe its final release. Does not issue a USB request.
+ (NSString *)traceDeviceLifetime:(IOUSBHostDevice *)device;
- (nullable instancetype)initWithDevice:(IOUSBHostDevice *)device error:(NSError **)error;
- (nullable NSData *)readCapacityWithError:(NSError **)error;
- (nullable NSData *)readBlocksAtLBA:(uint32_t)lba count:(uint16_t)count error:(NSError **)error;
- (BOOL)writeBlocksAtLBA:(uint32_t)lba data:(NSData *)data error:(NSError **)error;
- (void)close;
@end
NS_ASSUME_NONNULL_END
