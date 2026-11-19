import Darwin
import Foundation
import NS58Core
import ZIPFoundation

extension SupportedFirmware {
    private static let maxImportEntries = 64
    private static let maxDeclaredExpansion: UInt64 = 1024 * 1024

    /// Import a user-selected BIN or ZIP as verified NS58 V3.7 bytes. A manual
    /// ZIP may be repackaged, but its BIN must still match the existing release
    /// size and SHA-256. This never extracts archive paths to the filesystem.
    public static func importFirmware(from url: URL) throws -> Data {
        guard url.isFileURL else { throw NS58Error.invalid("Firmware import requires a local file") }
        let kind = url.pathExtension.lowercased()
        guard kind == "bin" || kind == "zip" else {
            throw NS58Error.invalid("Choose a supported NS58 .bin or .zip file")
        }
        let bytes = try readBoundedFile(url, limit: kind == "bin" ? NS58Constants.firmwareSize : maxArchiveBytes)
        if kind == "bin" {
            try NS58FAT12.verifyFirmware(bytes, filename: url.lastPathComponent)
            return bytes
        }
        return try importArchive(bytes)
    }

    private static func readBoundedFile(_ url: URL, limit: Int) throws -> Data {
        // NONBLOCK prevents an accidentally selected FIFO from blocking before
        // fstat can reject it. NOFOLLOW excludes a substituted symbolic link.
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw NS58Error.invalid("Firmware import requires a regular file")
        }
        guard info.st_size > 0, info.st_size <= Int64(limit) else {
            throw NS58Error.invalid("Firmware input is empty or exceeds its size limit")
        }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(16 * 1024, limit - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else {
                throw NS58Error.invalid("Firmware input grew beyond its size limit while reading")
            }
            result.append(chunk)
        }
        return result
    }

    private static func importArchive(_ bytes: Data) throws -> Data {
        // Preserve support for the exact reviewed original package, including
        // its legacy-encoded notes. Only the existing fully pinned decoder may
        // bypass the stricter path policy applied to arbitrary repackaged ZIPs.
        if NS58FAT12.sha256(bytes) == archiveSHA256 { return try extract(from: bytes) }
        let declaredCount = try standardZIPEntryCount(bytes)
        let archive = try Archive(data: bytes, accessMode: .read)
        var count = 0
        var expanded: UInt64 = 0
        var seenPaths = Set<String>()
        var target: Entry?
        for entry in archive {
            count += 1
            guard count <= maxImportEntries else { throw NS58Error.invalid("ZIP contains too many entries") }
            let components = try safeComponents(entry.path, isDirectory: entry.type == .directory)
            guard seenPaths.insert(entry.path).inserted else { throw NS58Error.invalid("ZIP contains duplicate entry paths") }
            guard entry.type != .symlink else { throw NS58Error.invalid("ZIP symbolic links are not supported") }
            guard entry.compressedSize <= UInt64(maxArchiveBytes),
                  entry.uncompressedSize <= maxDeclaredExpansion - expanded else {
                throw NS58Error.invalid("ZIP declared expansion exceeds the import limit")
            }
            expanded += entry.uncompressedSize
            guard let basename = components.last,
                  basename.caseInsensitiveCompare(NS58Constants.firmwareName) == .orderedSame else { continue }
            guard basename == NS58Constants.firmwareName, entry.type == .file,
                  entry.uncompressedSize == UInt64(NS58Constants.firmwareSize) else {
                throw NS58Error.invalid("ZIP firmware entry has an unexpected name, type, or size")
            }
            guard components.count <= 2 else {
                throw NS58Error.invalid("ZIP firmware must be at the root or one ordinary folder deep")
            }
            guard target == nil else { throw NS58Error.invalid("ZIP contains more than one expected firmware BIN") }
            target = entry
        }
        guard count == declaredCount else { throw NS58Error.invalid("ZIP central directory is incomplete or malformed") }
        guard let target else { throw NS58Error.invalid("ZIP does not contain the supported NS58 V3.7 BIN") }
        var firmware = Data()
        let crc = try archive.extract(target, bufferSize: 16 * 1024) { chunk in
            guard chunk.count <= NS58Constants.firmwareSize - firmware.count else {
                throw NS58Error.invalid("Extracted firmware exceeds its expected size")
            }
            firmware.append(chunk)
        }
        guard crc == target.checksum else { throw NS58Error.invalid("Firmware ZIP CRC mismatch") }
        try NS58FAT12.verifyFirmware(firmware, filename: NS58Constants.firmwareName)
        return firmware
    }

    private static func safeComponents(_ path: String, isDirectory: Bool) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw NS58Error.invalid("ZIP contains an unsafe entry path")
        }
        var components = path.components(separatedBy: "/")
        if isDirectory, components.last == "" { components.removeLast() }
        guard !components.isEmpty, components.count <= 8,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NS58Error.invalid("ZIP contains an unsafe entry path")
        }
        return components
    }

    /// Tiny firmware packages need neither ZIP64 nor split archives. Check the
    /// ordinary footer and entry count before using ZIPFoundation's iterator,
    /// whose early termination alone cannot distinguish a malformed directory.
    private static func standardZIPEntryCount(_ bytes: Data) throws -> Int {
        guard bytes.count >= 22, bytes.count <= maxArchiveBytes,
              bytes.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw NS58Error.invalid("Invalid or unsupported firmware ZIP")
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt64 {
            UInt64(bytes[at]) | UInt64(bytes[at + 1]) << 8 | UInt64(bytes[at + 2]) << 16 | UInt64(bytes[at + 3]) << 24
        }
        var footers: [Int] = []
        for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1) {
            if bytes[index] == 0x50, bytes[index+1] == 0x4b, bytes[index+2] == 0x05, bytes[index+3] == 0x06,
               index + 22 + u16(index + 20) == bytes.count { footers.append(index) }
        }
        guard footers.count == 1, let footer = footers.first,
              u16(footer + 4) == 0, u16(footer + 6) == 0,
              u16(footer + 8) == u16(footer + 10) else {
            throw NS58Error.invalid("Malformed or split firmware ZIP is not supported")
        }
        let count = u16(footer + 10)
        guard count > 0, count <= maxImportEntries else { throw NS58Error.invalid("ZIP contains too many or no entries") }
        let directorySize = u32(footer + 12), directoryOffset = u32(footer + 16)
        guard directoryOffset < UInt64(footer), directoryOffset + directorySize == UInt64(footer) else {
            throw NS58Error.invalid("ZIP central directory bounds are invalid")
        }
        // ZIPFoundation intentionally guesses unknown Unix file types as files.
        // Reject FIFOs, device nodes, and sockets rather than treating one as a
        // regular firmware entry. No entry is ever materialized on disk.
        var cursor = Int(directoryOffset)
        for _ in 0..<count {
            guard cursor <= footer - 46, u32(cursor) == 0x0201_4b50 else {
                throw NS58Error.invalid("ZIP central directory is incomplete or malformed")
            }
            let recordSize = 46 + u16(cursor + 28) + u16(cursor + 30) + u16(cursor + 32)
            guard recordSize <= footer - cursor else {
                throw NS58Error.invalid("ZIP central directory is incomplete or malformed")
            }
            let creator = u16(cursor + 4) >> 8
            if creator == 3 || creator == 19 {
                let mode = (u32(cursor + 38) >> 16) & 0xf000
                guard [0, 0x8000, 0x4000, 0xa000].contains(mode) else {
                    throw NS58Error.invalid("ZIP special file entries are not supported")
                }
            }
            cursor += recordSize
        }
        guard cursor == footer else { throw NS58Error.invalid("ZIP central directory contains unexpected records") }
        return count
    }
}
