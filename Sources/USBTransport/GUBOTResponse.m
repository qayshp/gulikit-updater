#import "GUBOTResponse.h"

NSErrorDomain const GUBOTResponseErrorDomain = @"GuliKitBOTResponse";

typedef struct {
    uint32_t tag;
    uint32_t residue;
    uint8_t status;
} GUCSWFields;

static uint32_t GUReadLE32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static BOOL GUResponseFail(NSError **error, GUBOTResponseError code,
                           NSString *message, NSData *packet) {
    if (error) {
        NSString *description = [NSString stringWithFormat:@"%@; packet[%lu]=%@",
            message, (unsigned long)packet.length, [GUBOTResponse boundedHexDump:packet]];
        *error = [NSError errorWithDomain:GUBOTResponseErrorDomain code:code
            userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

static BOOL GUParseCSW(NSData *packet, uint32_t expectedTag,
                        GUCSWFields *fields, NSError **error) {
    if (packet.length != 13) {
        return GUResponseFail(error, GUBOTResponseErrorUnexpectedLength,
            @"CSW must contain exactly 13 bytes", packet);
    }
    const uint8_t *bytes = packet.bytes;
    if (memcmp(bytes, "USBS", 4) != 0) {
        return GUResponseFail(error, GUBOTResponseErrorInvalidSignature,
            @"Invalid CSW signature; expected USBS", packet);
    }
    fields->tag = GUReadLE32(bytes + 4);
    fields->residue = GUReadLE32(bytes + 8);
    fields->status = bytes[12];
    if (fields->tag != expectedTag) {
        return GUResponseFail(error, GUBOTResponseErrorMismatchedTag,
            [NSString stringWithFormat:@"CSW tag mismatch (expected=0x%08x actual=0x%08x)",
                expectedTag, fields->tag], packet);
    }
    if (fields->status > 2) {
        return GUResponseFail(error, GUBOTResponseErrorInvalidStatus,
            [NSString stringWithFormat:@"Invalid CSW status (status=%u residue=%u)",
                fields->status, fields->residue], packet);
    }
    return YES;
}

@implementation GUBOTResponse
+ (NSData *)capacityPayloadFromPacket:(NSData *)packet expectedTag:(uint32_t)expectedTag
    error:(NSError **)error {
    // Length takes precedence over a signature-looking data prefix. The eight
    // capacity bytes are not a CSW, even if their first four bytes spell USBS.
    if (packet.length == 8) return [packet copy];
    if (packet.length == 13) {
        GUCSWFields fields = {0};
        if (!GUParseCSW(packet, expectedTag, &fields, error)) return nil;
        if (fields.residue > 8 && fields.status != 2) {
            GUResponseFail(error, GUBOTResponseErrorInvalidResidue,
                [NSString stringWithFormat:@"CSW residue exceeds READ CAPACITY transfer length (status=%u residue=%u)",
                    fields.status, fields.residue], packet);
            return nil;
        }
        GUResponseFail(error, GUBOTResponseErrorPrematureCSW,
            [NSString stringWithFormat:@"Premature CSW in READ CAPACITY data stage (tag=0x%08x status=%u residue=%u); capacity bytes missing",
                fields.tag, fields.status, fields.residue], packet);
        return nil;
    }
    GUResponseFail(error, GUBOTResponseErrorUnexpectedLength,
        @"READ CAPACITY requires exactly 8 data bytes; received neither capacity data nor a 13-byte CSW", packet);
    return nil;
}

+ (BOOL)validateCSW:(NSData *)packet expectedTag:(uint32_t)expectedTag error:(NSError **)error {
    GUCSWFields fields = {0};
    if (!GUParseCSW(packet, expectedTag, &fields, error)) return NO;
    if (fields.residue != 0) {
        return GUResponseFail(error, GUBOTResponseErrorNonzeroResidue,
            [NSString stringWithFormat:@"CSW reports nonzero residue (status=%u residue=%u)",
                fields.status, fields.residue], packet);
    }
    if (fields.status != 0) {
        return GUResponseFail(error, GUBOTResponseErrorCommandFailed,
            [NSString stringWithFormat:@"CSW command did not pass (status=%u residue=%u)",
                fields.status, fields.residue], packet);
    }
    return YES;
}

+ (NSString *)boundedHexDump:(NSData *)packet {
    if (packet.length == 0) return @"<empty>";
    const uint8_t *bytes = packet.bytes;
    NSUInteger shown = MIN(packet.length, (NSUInteger)64);
    NSMutableString *result = [NSMutableString stringWithCapacity:256];
    for (NSUInteger index = 0; index < shown; index++) {
        if (index) [result appendString:@" "];
        [result appendFormat:@"%02x", bytes[index]];
    }
    if (shown < packet.length) {
        [result appendFormat:@" ... (%lu bytes total; first 64 shown)", (unsigned long)packet.length];
    }
    return result;
}
@end
