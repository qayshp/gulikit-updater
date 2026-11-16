#import "GUBOTResetPolicy.h"
#import <CoreFoundation/CFByteOrder.h>

@implementation GUBOTResetPolicy {
    BOOL _attempted;
}

- (BOOL)attempted {
    @synchronized (self) { return _attempted; }
}

- (BOOL)beginWithCommandCount:(uint32_t)commandCount writingStarted:(BOOL)writingStarted
    error:(NSError **)error {
    @synchronized (self) {
        NSInteger code = 0;
        NSString *message = nil;
        if (_attempted) {
            code = 1;
            message = @"BOT reset recovery was already attempted on this transport; no retry is permitted";
        } else if (writingStarted) {
            code = 2;
            message = @"BOT reset recovery is forbidden after firmware writing has started";
        } else if (commandCount != 0) {
            code = 3;
            message = @"BOT reset recovery is permitted only before the first SCSI command";
        }
        if (code != 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"GuliKitBOTReset" code:code
                    userInfo:@{NSLocalizedDescriptionKey: message}];
            }
            return NO;
        }
        // The caller must not issue I/O before this reservation succeeds. Keep
        // the flag consumed even when its ensuing reset or clear-halt fails.
        _attempted = YES;
        return YES;
    }
}

+ (NSArray<NSNumber *> *)steps {
    return @[@(GUBOTResetStepClassReset), @(GUBOTResetStepClearBulkIn), @(GUBOTResetStepClearBulkOut)];
}

+ (IOUSBDeviceRequest)bulkOnlyResetRequest {
    IOUSBDeviceRequest request = {0};
    request.bmRequestType = 0x21; // Host-to-device, class, interface.
    request.bRequest = 0xFF;     // Bulk-Only Mass Storage Reset, not USB device reset.
    request.wValue = 0;
    request.wIndex = CFSwapInt16HostToLittle(3);
    request.wLength = 0;
    return request;
}
@end
