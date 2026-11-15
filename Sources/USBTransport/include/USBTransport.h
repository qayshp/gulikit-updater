#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>
#import "GUBOTResponse.h"

NS_ASSUME_NONNULL_BEGIN
/// Open only after AAUSBAccessory has granted this app exclusive ownership.
@interface GUUSBTransport : NSObject
- (nullable instancetype)initWithDevice:(IOUSBHostDevice *)device error:(NSError **)error;
- (nullable NSData *)readCapacityWithError:(NSError **)error;
- (nullable NSData *)readBlocksAtLBA:(uint32_t)lba count:(uint16_t)count error:(NSError **)error;
- (BOOL)writeBlocksAtLBA:(uint32_t)lba data:(NSData *)data error:(NSError **)error;
- (void)close;
@end
NS_ASSUME_NONNULL_END
