#import "USBTransport.h"
#import <IOKit/IOKitLib.h>
#import <os/log.h>

static void GUTrace(NSString *message) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.qayshp.GuliKitUpdater", "usb-inspection"); });
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "%{public}s", message.UTF8String);
}

static BOOL GUFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"GuliKitUSB" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
static void putLE32(uint8_t *p, uint32_t x) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(x >> (8 * i));
}
static uint32_t getLE32(const uint8_t *p) {
    return p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static NSSet<NSNumber *> *GUInterfaceIDs(io_service_t device, NSError **error) {
    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(device, kIOServicePlane,
        kIORegistryIterateRecursively, &children) != KERN_SUCCESS) {
        GUFail(error, @"Cannot snapshot USB interfaces before configuration"); return nil;
    }
    NSMutableSet<NSNumber *> *ids = [NSMutableSet set];
    io_service_t service;
    while ((service = IOIteratorNext(children))) {
        uint64_t entryID = 0;
        if (IOObjectConformsTo(service, "IOUSBHostInterface")
            && IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS) {
            [ids addObject:@(entryID)];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(children);
    return ids;
}

@implementation GUUSBTransport {
    IOUSBHostInterface *_interface;
    IOUSBHostPipe *_input;
    IOUSBHostPipe *_output;
    uint8_t _inputAddress;
    uint8_t _outputAddress;
    uint32_t _tag;
    BOOL _writeStarted;
}
- (instancetype)initWithDevice:(IOUSBHostDevice *)device error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSSet<NSNumber *> *oldInterfaces = GUInterfaceIDs(device.ioService, error);
    if (!oldInterfaces) return nil;
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    // AccessoryAccess grants exclusive ownership. Its device may already be
    // configured; do not tear down an existing configuration unnecessarily.
    // If configuration is needed, suppress normal mass-storage matching.
    const IOUSBConfigurationDescriptor *currentConfiguration = device.configurationDescriptor;
    BOOL needsConfiguration = !currentConfiguration || currentConfiguration->bConfigurationValue != 1;
    if (needsConfiguration && ![device configureWithValue:1 matchInterfaces:NO error:error]) return nil;
    GUTrace(needsConfiguration ? @"USB configuration 1 selected with matching suppressed"
        : @"USB configuration 1 already selected; redundant SET_CONFIGURATION skipped");
    uint64_t selectedID = 0;
    for (int attempt = 0; attempt < 100 && !_interface; attempt++) {
        io_iterator_t children = IO_OBJECT_NULL;
        if (IORegistryEntryCreateIterator(device.ioService, kIOServicePlane,
            kIORegistryIterateRecursively, &children) != KERN_SUCCESS) {
            GUFail(error, @"Cannot enumerate claimed USB interfaces"); return nil;
        }
        io_service_t service;
        while ((service = IOIteratorNext(children))) {
            if (IOObjectConformsTo(service, "IOUSBHostInterface")) {
                CFTypeRef number = IORegistryEntryCreateCFProperty(service, CFSTR("bInterfaceNumber"),
                    kCFAllocatorDefault, 0);
                BOOL matches = number && CFGetTypeID(number) == CFNumberGetTypeID()
                    && [(__bridge NSNumber *)number intValue] == 3;
                if (number) CFRelease(number);
                uint64_t entryID = 0;
                BOOL identified = IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS;
                if (matches && identified) {
                    _interface = [[IOUSBHostInterface alloc] initWithIOService:service
                        options:IOUSBHostObjectInitOptionsNone queue:nil error:error interestHandler:nil];
                    selectedID = entryID;
                    IOObjectRelease(service);
                    break;
                }
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(children);
        if (!_interface && error && *error) return nil;
        if (!_interface) [NSThread sleepForTimeInterval:0.02];
    }
    if (!_interface) { GUFail(error, @"NS58 USB interface 3 did not appear within 2 seconds"); return nil; }
    const IOUSBInterfaceDescriptor *d = _interface.interfaceDescriptor;
    if (d->bInterfaceNumber != 3 || d->bAlternateSetting != 0 || d->bInterfaceClass != 8
        || d->bInterfaceSubClass != 6 || d->bInterfaceProtocol != 0x50 || d->bNumEndpoints != 2) {
        GUFail(error, @"USB interface does not match the NS58 mass-storage updater");
        [self close]; return nil;
    }
    const IOUSBConfigurationDescriptor *config = _interface.configurationDescriptor;
    const uint8_t *base = (const uint8_t *)config;
    NSUInteger total = CFSwapInt16LittleToHost(config->wTotalLength);
    BOOL inside = NO;
    for (NSUInteger offset = 0; offset + 2 <= total;) {
        uint8_t length = base[offset], type = base[offset + 1];
        if (length < 2 || offset + length > total) break;
        if (type == 4 && length >= 9) inside = base[offset+2] == 3 && base[offset+3] == 0;
        if (inside && type == 5 && length >= 7) {
            uint8_t address = base[offset+2];
            uint16_t packet = base[offset+4] | (base[offset+5] << 8);
            if ((base[offset+3] & 3) != 2 || packet != 64) {
                GUFail(error, @"Unexpected NS58 endpoint geometry"); [self close]; return nil;
            }
            IOUSBHostPipe *pipe = [_interface copyPipeWithAddress:address error:error];
            if (!pipe) { [self close]; return nil; }
            if (pipe.endpointAddress != address || pipe.deviceAddress != device.deviceAddress) {
                GUFail(error, @"USB pipe identity differs from the configured NS58");
                [self close]; return nil;
            }
            if (address & 0x80) { _input = pipe; _inputAddress = address; }
            else { _output = pipe; _outputAddress = address; }
        }
        offset += length;
    }
    if (!_input || !_output) {
        GUFail(error, @"Missing NS58 bulk endpoint pair"); [self close]; return nil;
    }
    GUTrace([NSString stringWithFormat:
        @"USB interface registry=%llu device=%lu IN=0x%02x OUT=0x%02x configured/opened in %.1f ms (pre-config interfaces=%lu retained ID=%@)",
        (unsigned long long)selectedID, _input.deviceAddress, _inputAddress, _outputAddress,
        (NSProcessInfo.processInfo.systemUptime - started) * 1000, oldInterfaces.count,
        [oldInterfaces containsObject:@(selectedID)] ? @"YES" : @"NO"]);
    return self;
}
- (BOOL)transfer:(IOUSBHostPipe *)pipe data:(NSMutableData *)data
    phase:(NSString *)phase error:(NSError **)error {
    NSUInteger transferred = 0;
    NSError *underlying = nil;
    if (![pipe sendIORequestWithData:data bytesTransferred:&transferred completionTimeout:10 error:&underlying]) {
        uint8_t address = pipe == _input ? _inputAddress : _outputAddress;
        if (error) {
            NSString *message = [NSString stringWithFormat:
                @"%@ on endpoint 0x%02x failed (%lu/%lu bytes): %@ (%@, 0x%08x)",
                phase, address, transferred, data.length, underlying.localizedDescription,
                underlying.domain, (uint32_t)underlying.code];
            NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
            if (underlying) info[NSUnderlyingErrorKey] = underlying;
            *error = [NSError errorWithDomain:@"GuliKitUSB" code:2 userInfo:info];
        }
        return NO;
    }
    return transferred == data.length || GUFail(error,
        [NSString stringWithFormat:@"%@ short USB transfer: %lu of %lu bytes", phase, transferred, data.length]);
}
- (NSData *)command:(const uint8_t *)cdb length:(NSUInteger)length input:(BOOL)input
    payload:(NSData *)payload count:(NSUInteger)count error:(NSError **)error {
    if (!_input || !_output) { GUFail(error, @"USB transport is closed"); return nil; }
    NSMutableData *cbw = [NSMutableData dataWithLength:31];
    uint8_t *p = cbw.mutableBytes;
    memcpy(p, "USBC", 4); putLE32(p+4, ++_tag); putLE32(p+8, (uint32_t)count);
    p[12] = input ? 0x80 : 0; p[13] = 0; p[14] = (uint8_t)length;
    memcpy(p+15, cdb, length);
    NSString *command = [NSString stringWithFormat:@"SCSI 0x%02x", cdb[0]];
    if (![self transfer:_output data:cbw phase:[command stringByAppendingString:@" CBW OUT"] error:error]) return nil;
    NSMutableData *data = input ? [NSMutableData dataWithLength:count] : [payload mutableCopy];
    if (count && ![self transfer:input ? _input : _output data:data
        phase:[command stringByAppendingString:input ? @" data IN" : @" data OUT"] error:error]) return nil;
    NSMutableData *csw = [NSMutableData dataWithLength:13];
    if (![self transfer:_input data:csw phase:[command stringByAppendingString:@" CSW IN"] error:error]) return nil;
    const uint8_t *s = csw.bytes;
    if (memcmp(s, "USBS", 4) || getLE32(s+4) != _tag || getLE32(s+8) != 0 || s[12] != 0) {
        GUFail(error, [NSString stringWithFormat:@"Invalid or failed BOT status (status=%u residue=%u)",
            s[12], getLE32(s+8)]); return nil;
    }
    return data ?: [NSData data];
}
- (NSData *)readCapacityWithError:(NSError **)error {
    // Capacity is an initialization diagnostic, separate from the proven write
    // path. Keep the command's declared data length at 8, but receive a complete
    // endpoint packet so an unexpected 13-byte CSW is observable, not an overrun.
    if (_writeStarted || !_input || !_output) {
        GUFail(error, @"Capacity inspection is unavailable after writing or transport closure"); return nil;
    }
    NSMutableData *cbw = [NSMutableData dataWithLength:31];
    uint8_t *p = cbw.mutableBytes;
    memcpy(p, "USBC", 4); putLE32(p+4, ++_tag); putLE32(p+8, 8);
    p[12] = 0x80; p[14] = 10; p[15] = 0x25;
    if (![self transfer:_output data:cbw phase:@"SCSI 0x25 CBW OUT" error:error]) return nil;
    NSData *packet = [self receiveInspectionPacket:@"capacity data" error:error];
    if (!packet) return nil;
    NSData *capacity = [GUBOTResponse capacityPayloadFromPacket:packet expectedTag:_tag error:error];
    if (!capacity) { [self close]; return nil; }
    NSData *status = [self receiveInspectionPacket:@"capacity CSW" error:error];
    if (!status) return nil;
    if (![GUBOTResponse validateCSW:status expectedTag:_tag error:error]) { [self close]; return nil; }
    return capacity;
}
- (NSData *)receiveInspectionPacket:(NSString *)phase error:(NSError **)error {
    NSMutableData *buffer = [NSMutableData dataWithLength:64];
    NSUInteger transferred = 0;
    NSError *underlying = nil;
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    BOOL success = [_input sendIORequestWithData:buffer bytesTransferred:&transferred
        completionTimeout:10 error:&underlying];
    NSTimeInterval milliseconds = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
    if (!success || transferred > buffer.length) {
        NSString *message = [NSString stringWithFormat:
            @"SCSI 0x25 %@ IN tag=%u endpoint=0x%02x failed (%lu/64 bytes, %.1f ms): %@ (%@, 0x%08x). Fresh connection required; no retry.",
            phase, _tag, _inputAddress, transferred, milliseconds, underlying.localizedDescription,
            underlying.domain, (uint32_t)underlying.code];
        if (error) {
            NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
            if (underlying) info[NSUnderlyingErrorKey] = underlying;
            *error = [NSError errorWithDomain:@"GuliKitUSB" code:3 userInfo:info];
        }
        [self close]; return nil;
    }
    NSData *packet = [buffer subdataWithRange:NSMakeRange(0, transferred)];
    GUTrace([NSString stringWithFormat:@"SCSI 0x25 %@ IN tag=%u endpoint=0x%02x received=%lu/64 in %.1f ms bytes=%@",
        phase, _tag, _inputAddress, transferred, milliseconds, [GUBOTResponse boundedHexDump:packet]]);
    return packet;
}
- (NSData *)readBlocksAtLBA:(uint32_t)lba count:(uint16_t)count error:(NSError **)error {
    if (_writeStarted || count == 0 || (uint64_t)lba + count > 119) {
        GUFail(error, @"Read outside NS58 preflight bounds"); return nil;
    }
    uint8_t cdb[10] = {0x28,0,(uint8_t)(lba>>24),(uint8_t)(lba>>16),(uint8_t)(lba>>8),(uint8_t)lba,
        0,(uint8_t)(count>>8),(uint8_t)count,0};
    return [self command:cdb length:10 input:YES payload:nil count:(NSUInteger)count * 4096 error:error];
}
- (BOOL)writeBlocksAtLBA:(uint32_t)lba data:(NSData *)data error:(NSError **)error {
    // Only the two capture-derived writes are expressible here, in order.
    BOOL valid = (!_writeStarted && lba == 10 && data.length == 13*4096)
        || (_writeStarted && lba == 1 && data.length == 3*4096);
    if (!valid) return GUFail(error, @"Write does not match NS58 firmware transaction");
    if (!_writeStarted) _writeStarted = YES;
    uint16_t count = (uint16_t)(data.length / 4096);
    uint8_t cdb[10] = {0x2a,0,(uint8_t)(lba>>24),(uint8_t)(lba>>16),(uint8_t)(lba>>8),(uint8_t)lba,
        0,(uint8_t)(count>>8),(uint8_t)count,0};
    BOOL success = [self command:cdb length:10 input:NO payload:data count:data.length error:error] != nil;
    // A failed command, or completion of metadata, permanently closes this writer.
    if (!success || lba == 1) { _output = nil; _input = nil; }
    return success;
}
- (void)close {
    _input = nil; _output = nil;
    [_interface destroy]; _interface = nil;
}
- (void)dealloc { [self close]; }
@end
