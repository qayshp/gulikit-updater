#import <Foundation/Foundation.h>
#import <IOUSBHost/IOUSBHost.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GUBOTResetStep) {
    GUBOTResetStepClassReset = 0,
    GUBOTResetStepClearBulkIn = 1,
    GUBOTResetStepClearBulkOut = 2,
};

/// Pure one-shot permission policy and request construction. Does not perform
/// USB operations, clear endpoints, or send any storage command itself.
@interface GUBOTResetPolicy : NSObject
@property(readonly) BOOL attempted;

/// The exact reset-recovery order: class reset, clear bulk IN, clear bulk OUT.
@property(class, readonly, copy) NSArray<NSNumber *> *steps;

/// Begins one pre-command reset attempt. A valid begin consumes the attempt
/// immediately, before the caller issues I/O. Invalid begins do not consume it.
- (BOOL)beginWithCommandCount:(uint32_t)commandCount
              writingStarted:(BOOL)writingStarted
                       error:(NSError * _Nullable *)error
    NS_SWIFT_NAME(begin(commandCount:writingStarted:));

/// Builds only the NS58 interface-3 Bulk-Only Mass Storage Reset request.
+ (IOUSBDeviceRequest)bulkOnlyResetRequest NS_SWIFT_NAME(bulkOnlyResetRequest());
@end

NS_ASSUME_NONNULL_END
