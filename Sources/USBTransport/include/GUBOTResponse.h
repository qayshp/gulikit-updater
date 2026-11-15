#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const GUBOTResponseErrorDomain;

typedef NS_ERROR_ENUM(GUBOTResponseErrorDomain, GUBOTResponseError) {
    GUBOTResponseErrorUnexpectedLength = 10,
    GUBOTResponseErrorInvalidSignature = 11,
    GUBOTResponseErrorMismatchedTag = 12,
    GUBOTResponseErrorInvalidStatus = 13,
    GUBOTResponseErrorInvalidResidue = 14,
    GUBOTResponseErrorPrematureCSW = 15,
    GUBOTResponseErrorNonzeroResidue = 16,
    GUBOTResponseErrorCommandFailed = 17,
};

/// Stateless parsers only. These helpers do not access USB or send commands.
@interface GUBOTResponse : NSObject
- (instancetype)init NS_UNAVAILABLE;

/// Accepts exactly eight capacity-data bytes. The caller must still validate
/// their geometry against the expected device. A matching thirteen-byte CSW
/// is diagnosed as a premature status response, never returned as capacity.
+ (nullable NSData *)capacityPayloadFromPacket:(NSData *)packet
                                  expectedTag:(uint32_t)expectedTag
                                        error:(NSError * _Nullable *)error
    NS_SWIFT_NAME(capacityPayload(from:expectedTag:));

/// Requires exactly thirteen bytes, USBS signature, matching tag, zero residue,
/// and successful command status. Does not apply any device-compatibility quirk.
+ (BOOL)validateCSW:(NSData *)packet
       expectedTag:(uint32_t)expectedTag
             error:(NSError * _Nullable *)error
    NS_SWIFT_NAME(validateCSW(_:expectedTag:));

/// Hex rendering of at most the first 64 bytes, with total length if truncated.
+ (NSString *)boundedHexDump:(NSData *)packet NS_SWIFT_NAME(boundedHexDump(_:));
@end

NS_ASSUME_NONNULL_END
