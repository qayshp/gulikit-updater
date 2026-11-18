import Foundation

/// A read-only observation of the updater's root-directory volume label.
/// Neither the label nor a parsed version authenticates the controller model
/// or establishes that the strict firmware writer can accept this session.
public struct NS58VersionObservation: Equatable, Sendable {
    public let volumeLabel: String
    public let version: String?
}

/// Reads version-bearing labels without applying the V3.7 writer's clean-image
/// requirements. The supported geometry is still the captured NS58 FAT12
/// profile; this is not a general-purpose FAT or GuliKit model detector.
public enum NS58VersionProbe {
    private static let sectorBytes = 4_096
    private static let maximumProbeBytes = 23 * sectorBytes

    public static func inspect(_ image: Data) throws -> NS58VersionObservation {
        // Copy only the bounded preflight window. Array indexing also remains
        // zero-based when the caller passes a Data slice with a nonzero index.
        let bytes = Array(image.prefix(maximumProbeBytes))
        guard bytes.count >= 512 else {
            throw NS58Error.invalid("Version observation is missing the FAT boot sector")
        }
        guard bytes[510] == 0x55, bytes[511] == 0xAA else {
            throw NS58Error.invalid("Version observation has no FAT boot signature")
        }
        guard Array(bytes[3..<11]) == Array("MSDOS5.0".utf8) else {
            throw NS58Error.invalid("Version observation has an unexpected FAT OEM name")
        }

        let bytesPerSector = u16(bytes, at: 11)
        let reservedSectors = u16(bytes, at: 14)
        let fatCopies = Int(bytes[16])
        let rootEntries = u16(bytes, at: 17)
        let sectorsPerFAT = u16(bytes, at: 22)
        guard bytesPerSector == sectorBytes,
              bytes[13] == 1,
              reservedSectors == 1,
              fatCopies == 2,
              rootEntries == 512,
              u16(bytes, at: 19) == 123,
              sectorsPerFAT == 1,
              Array(bytes[54..<62]) == Array("FAT12   ".utf8)
        else {
            throw NS58Error.invalid("Version observation geometry does not match the captured NS58 FAT12 profile")
        }

        // All factors are constrained above before arithmetic or indexing.
        let rootStart = (reservedSectors + fatCopies * sectorsPerFAT) * bytesPerSector
        let rootBytes = rootEntries * 32
        guard rootStart <= bytes.count, rootBytes <= bytes.count - rootStart else {
            throw NS58Error.invalid("Version observation does not contain the complete FAT12 root directory")
        }

        var volumeLabel: String?
        for index in 0..<rootEntries {
            let start = rootStart + index * 32
            let entry = Array(bytes[start..<(start + 32)])
            if entry[0] == 0x00 { break } // Remaining entries are unallocated.
            if entry[0] == 0xE5 { continue } // Deleted entry.
            let attributes = entry[11]
            if attributes == 0x0F { continue } // VFAT LFN also has the volume bit.
            if attributes & 0x08 == 0 { continue }

            guard attributes == 0x08,
                  u16(entry, at: 20) == 0,
                  u16(entry, at: 26) == 0,
                  entry[28..<32].allSatisfy({ $0 == 0 }) else {
                throw NS58Error.invalid("Version observation contains a malformed root volume-label entry")
            }
            guard volumeLabel == nil else {
                throw NS58Error.invalid("Version observation contains ambiguous duplicate volume labels")
            }
            let rawLabel = Array(entry[0..<11])
            guard rawLabel.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
                throw NS58Error.invalid("Version observation volume label is not readable ASCII")
            }
            let unpadded = rawLabel.reversed().drop(while: { $0 == 0x20 }).reversed()
            guard !unpadded.isEmpty else {
                throw NS58Error.invalid("Version observation volume label is empty")
            }
            volumeLabel = String(decoding: unpadded, as: UTF8.self)
        }

        guard let volumeLabel else {
            throw NS58Error.invalid("Version observation has no allocated root volume-label entry")
        }
        return NS58VersionObservation(volumeLabel: volumeLabel, version: parseVersion(volumeLabel))
    }

    private static func parseVersion(_ label: String) -> String? {
        let prefix = "GuliKit "
        guard label.hasPrefix(prefix) else { return nil }
        let version = String(label.dropFirst(prefix.count))
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ component in
                  !component.isEmpty && component.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
              }) else { return nil }
        return version
    }

    private static func u16(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }
}
