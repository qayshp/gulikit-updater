import CryptoKit
import Foundation

public enum NS58Error: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

public enum NS58Constants {
    public static let firmwareName = "NS58_Elves2_V3.7.bin"
    public static let firmwareSize = 51_188
    public static let firmwareSHA256 =
        "486c308e857b24adde6e7b623af67c8d0a74b6038f57ffc41ea7e2b94683e1eb"
    public static let bytesPerSector = 4_096
    public static let reportedDeviceBytes = 487_424
    public static let firmwareStartLBA = 10
    public static let firmwareBlocks = 13
    public static let metadataStartLBA = 1
    public static let metadataBlocks = 3
    public static let firmwareStartCluster = 5
    public static let firmwareClusterCount = 13
    public static let rootDirectoryLBA = 3
    public static let expectedVolumeLabel = "GuliKit 3.7"
    public static let expectedBootLabel = "NO NAME    "
    public static let shortName = Array("NS58_E~1BIN".utf8)
}

public struct NS58Inspection: Sendable {
    public let bytesPerSector: Int
    public let sectorsPerCluster: Int
    public let reservedSectors: Int
    public let fatCopies: Int
    public let rootEntryCount: Int
    public let sectorsPerFAT: Int
    public let bpbTotalSectors: Int
    public let availableBytes: Int
    public let volumeLabel: String
}

public struct NS58UpdatePlan: Sendable {
    public let firmwarePayload: Data
    public let metadataPayload: Data
    public let updatedImage: Data

    public var firmwareOffset: UInt64 {
        UInt64(NS58Constants.firmwareStartLBA * NS58Constants.bytesPerSector)
    }

    public var metadataOffset: UInt64 {
        UInt64(NS58Constants.metadataStartLBA * NS58Constants.bytesPerSector)
    }
}

public enum NS58FAT12 {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyFirmware(_ firmware: Data, filename: String) throws {
        guard filename == NS58Constants.firmwareName else {
            throw NS58Error.invalid(
                "firmware filename must be \(NS58Constants.firmwareName)"
            )
        }
        guard firmware.count == NS58Constants.firmwareSize else {
            throw NS58Error.invalid(
                "firmware size is \(firmware.count), expected \(NS58Constants.firmwareSize)"
            )
        }
        let digest = sha256(firmware)
        guard digest == NS58Constants.firmwareSHA256 else {
            throw NS58Error.invalid(
                "firmware SHA-256 is \(digest), expected \(NS58Constants.firmwareSHA256)"
            )
        }
    }

    public static func inspectBaseline(_ image: Data) throws -> NS58Inspection {
        let sector = NS58Constants.bytesPerSector
        guard image.count >= (NS58Constants.rootDirectoryLBA + 1) * sector else {
            throw NS58Error.invalid("image is too short to contain the FAT12 root")
        }
        guard image[510] == 0x55, image[511] == 0xAA else {
            throw NS58Error.invalid("missing FAT boot signature")
        }
        guard ascii(image, 3..<11) == "MSDOS5.0" else {
            throw NS58Error.invalid("unexpected FAT OEM name")
        }

        let bytesPerSector = int16(image, 11)
        let sectorsPerCluster = Int(image[13])
        let reserved = int16(image, 14)
        let fats = Int(image[16])
        let rootEntries = int16(image, 17)
        let totalSectors = int16(image, 19)
        let sectorsPerFAT = int16(image, 22)
        let bootLabel = ascii(image, 43..<54)
        let fatType = ascii(image, 54..<62)

        guard bytesPerSector == sector,
              sectorsPerCluster == 1,
              reserved == 1,
              fats == 2,
              rootEntries == 512,
              totalSectors == 123,
              sectorsPerFAT == 1,
              bootLabel == NS58Constants.expectedBootLabel,
              fatType == "FAT12   "
        else {
            throw NS58Error.invalid("FAT12 geometry does not match the NS58 updater")
        }

        let fat1 = image.subdata(in: sector..<(2 * sector))
        let fat2 = image.subdata(in: (2 * sector)..<(3 * sector))
        guard fat1 == fat2 else {
            throw NS58Error.invalid("baseline FAT copies differ")
        }
        let firmwareClusterEnd =
            NS58Constants.firmwareStartCluster + NS58Constants.firmwareClusterCount
        let firmwareClusterRange =
            NS58Constants.firmwareStartCluster..<firmwareClusterEnd
        for cluster in firmwareClusterRange {
            guard fat12Entry(fat1, cluster: cluster) == 0 else {
                throw NS58Error.invalid(
                    "firmware cluster \(cluster) is not free in the baseline FAT"
                )
            }
        }

        let rootStart = NS58Constants.rootDirectoryLBA * sector
        let root = image.subdata(in: rootStart..<(rootStart + sector))
        let volumeLabel = ascii(root, 0..<11)
        guard volumeLabel == NS58Constants.expectedVolumeLabel,
              root[11] == 0x08
        else {
            throw NS58Error.invalid("root volume label is not GuliKit 3.7")
        }
        guard root[32 + 11] == 0x0F,
              root[64 + 11] == 0x0F,
              root[96 + 11] == 0x16,
              ascii(root, 96..<107) == "SYSTEM~1   ",
              int16(root, 96 + 26) == 2
        else {
            throw NS58Error.invalid(
                "baseline System Volume Information entries are unexpected"
            )
        }
        guard root[128] == 0 else {
            throw NS58Error.invalid(
                "baseline root contains an entry where firmware must be created"
            )
        }

        return NS58Inspection(
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            reservedSectors: reserved,
            fatCopies: fats,
            rootEntryCount: rootEntries,
            sectorsPerFAT: sectorsPerFAT,
            bpbTotalSectors: totalSectors,
            availableBytes: image.count,
            volumeLabel: volumeLabel
        )
    }

    public static func makeUpdatePlan(
        baseline: Data,
        firmware: Data,
        firmwareFilename: String,
        timestamp: Date = Date()
    ) throws -> NS58UpdatePlan {
        _ = try inspectBaseline(baseline)
        try verifyFirmware(firmware, filename: firmwareFilename)

        let sector = NS58Constants.bytesPerSector
        var paddedFirmware = firmware
        paddedFirmware.append(
            Data(
                repeating: 0,
                count: NS58Constants.firmwareBlocks * sector - firmware.count
            )
        )

        var fat = baseline.subdata(in: sector..<(2 * sector))
        let first = NS58Constants.firmwareStartCluster
        let last = first + NS58Constants.firmwareClusterCount - 1
        for cluster in first..<last {
            setFAT12Entry(&fat, cluster: cluster, value: UInt16(cluster + 1))
        }
        setFAT12Entry(&fat, cluster: last, value: 0x0FFF)

        let rootStart = NS58Constants.rootDirectoryLBA * sector
        var root = baseline.subdata(in: rootStart..<(rootStart + sector))
        let filenameUnits = Array(NS58Constants.firmwareName.utf16)
        let short = NS58Constants.shortName
        let checksum = lfnChecksum(short)

        writeLFN(
            into: &root,
            offset: 128,
            order: 0x42,
            units: Array(filenameUnits.dropFirst(13)),
            checksum: checksum,
            isLastFragment: true
        )
        writeLFN(
            into: &root,
            offset: 160,
            order: 0x01,
            units: Array(filenameUnits.prefix(13)),
            checksum: checksum,
            isLastFragment: false
        )
        writeShortEntry(
            into: &root,
            offset: 192,
            timestamp: timestamp,
            size: firmware.count
        )
        root[224] = 0

        var metadata = Data()
        metadata.append(fat)
        metadata.append(fat)
        metadata.append(root)

        var updated = baseline
        let firmwareOffset =
            NS58Constants.firmwareStartLBA * NS58Constants.bytesPerSector
        let required = firmwareOffset + paddedFirmware.count
        guard updated.count >= required else {
            throw NS58Error.invalid(
                "image is too short for the firmware data sectors"
            )
        }
        updated.replaceSubrange(
            firmwareOffset..<required,
            with: paddedFirmware
        )
        updated.replaceSubrange(
            sector..<(sector + metadata.count),
            with: metadata
        )

        try verifyUpdatedImage(updated, firmware: firmware)
        return NS58UpdatePlan(
            firmwarePayload: paddedFirmware,
            metadataPayload: metadata,
            updatedImage: updated
        )
    }

    public static func verifyUpdatedImage(
        _ image: Data,
        firmware: Data
    ) throws {
        guard firmware.count == NS58Constants.firmwareSize else {
            throw NS58Error.invalid("unexpected firmware length")
        }
        guard image.count >= (NS58Constants.firmwareStartLBA + NS58Constants.firmwareBlocks)
            * NS58Constants.bytesPerSector else {
            throw NS58Error.invalid("updated image is too short")
        }
        let sector = NS58Constants.bytesPerSector
        let firmwareOffset = NS58Constants.firmwareStartLBA * sector
        let firmwareRange = firmwareOffset..<(firmwareOffset + firmware.count)
        guard image.subdata(in: firmwareRange) == firmware else {
            throw NS58Error.invalid("updated image firmware bytes differ")
        }
        let paddingStart = firmwareRange.upperBound
        let paddingEnd =
            firmwareOffset + NS58Constants.firmwareBlocks * sector
        guard image[paddingStart..<paddingEnd].allSatisfy({ $0 == 0 }) else {
            throw NS58Error.invalid("updated image padding is not zero")
        }

        let fat1 = image.subdata(in: sector..<(2 * sector))
        let fat2 = image.subdata(in: (2 * sector)..<(3 * sector))
        guard fat1 == fat2 else {
            throw NS58Error.invalid("updated FAT copies differ")
        }
        let first = NS58Constants.firmwareStartCluster
        let last = first + NS58Constants.firmwareClusterCount - 1
        for cluster in first..<last {
            guard fat12Entry(fat1, cluster: cluster) == UInt16(cluster + 1) else {
                throw NS58Error.invalid("updated FAT chain is invalid")
            }
        }
        guard fat12Entry(fat1, cluster: last) == 0x0FFF else {
            throw NS58Error.invalid("updated FAT chain lacks an end marker")
        }

        let rootStart = NS58Constants.rootDirectoryLBA * sector
        let root = image.subdata(in: rootStart..<(rootStart + sector))
        guard root[128] == 0x42,
              root[128 + 11] == 0x0F,
              root[160] == 0x01,
              root[160 + 11] == 0x0F,
              Array(root[192..<203]) == NS58Constants.shortName,
              root[192 + 11] == 0x20,
              int16(root, 192 + 26) == NS58Constants.firmwareStartCluster,
              int32(root, 192 + 28) == firmware.count
        else {
            throw NS58Error.invalid("updated root firmware entry is invalid")
        }
    }

    private static func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(decoding: data[range], as: UTF8.self)
    }

    private static func int16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func int32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
    }

    private static func fat12Entry(_ fat: Data, cluster: Int) -> UInt16 {
        let offset = cluster + cluster / 2
        if cluster.isMultiple(of: 2) {
            return UInt16(fat[offset])
                | (UInt16(fat[offset + 1] & 0x0F) << 8)
        }
        return (UInt16(fat[offset]) >> 4) | (UInt16(fat[offset + 1]) << 4)
    }

    private static func setFAT12Entry(
        _ fat: inout Data,
        cluster: Int,
        value: UInt16
    ) {
        let value = value & 0x0FFF
        let offset = cluster + cluster / 2
        if cluster.isMultiple(of: 2) {
            fat[offset] = UInt8(value & 0x00FF)
            fat[offset + 1] =
                (fat[offset + 1] & 0xF0) | UInt8((value >> 8) & 0x0F)
        } else {
            fat[offset] = (fat[offset] & 0x0F) | UInt8((value << 4) & 0xF0)
            fat[offset + 1] = UInt8((value >> 4) & 0x00FF)
        }
    }

    private static func lfnChecksum(_ shortName: [UInt8]) -> UInt8 {
        shortName.reduce(UInt8(0)) { checksum, byte in
            ((checksum & 1) == 1 ? 0x80 : 0)
                &+ (checksum >> 1)
                &+ byte
        }
    }

    private static func writeLFN(
        into root: inout Data,
        offset: Int,
        order: UInt8,
        units: [UInt16],
        checksum: UInt8,
        isLastFragment: Bool
    ) {
        var values = units
        if isLastFragment && values.count < 13 {
            values.append(0)
        }
        while values.count < 13 {
            values.append(0xFFFF)
        }
        root.replaceSubrange(offset..<(offset + 32), with: repeatElement(UInt8(0), count: 32))
        root[offset] = order
        root[offset + 11] = 0x0F
        root[offset + 12] = 0
        root[offset + 13] = checksum
        root[offset + 26] = 0
        root[offset + 27] = 0
        let locations = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
        for (value, location) in zip(values.prefix(13), locations) {
            root[offset + location] = UInt8(value & 0x00FF)
            root[offset + location + 1] = UInt8((value >> 8) & 0x00FF)
        }
    }

    private static func writeShortEntry(
        into root: inout Data,
        offset: Int,
        timestamp: Date,
        size: Int
    ) {
        root.replaceSubrange(offset..<(offset + 32), with: repeatElement(UInt8(0), count: 32))
        root.replaceSubrange(
            offset..<(offset + 11),
            with: NS58Constants.shortName
        )
        root[offset + 11] = 0x20

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: timestamp
        )
        let year = max(1980, min(2107, components.year ?? 1980))
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(59, components.second ?? 0))
        let dateValue = UInt16((year - 1980) << 9 | month << 5 | day)
        let timeValue = UInt16(hour << 11 | minute << 5 | second / 2)

        put16(&root, offset + 14, timeValue)
        put16(&root, offset + 16, dateValue)
        put16(&root, offset + 18, dateValue)
        put16(&root, offset + 22, timeValue)
        put16(&root, offset + 24, dateValue)
        put16(
            &root,
            offset + 26,
            UInt16(NS58Constants.firmwareStartCluster)
        )
        put32(&root, offset + 28, UInt32(size))
    }

    private static func put16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value & 0x00FF)
        data[offset + 1] = UInt8((value >> 8) & 0x00FF)
    }

    private static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0x000000FF)
        data[offset + 1] = UInt8((value >> 8) & 0x000000FF)
        data[offset + 2] = UInt8((value >> 16) & 0x000000FF)
        data[offset + 3] = UInt8((value >> 24) & 0x000000FF)
    }
}
