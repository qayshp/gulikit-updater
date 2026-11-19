import Foundation
import Testing
import ZIPFoundation
import FirmwareDownload
import NS58Core

struct ManualFirmwareImportTests {
    private struct Item {
        let path: String
        let type: Entry.EntryType
        let data: Data
        let compression: CompressionMethod
        init(_ path: String, _ data: Data = Data(), type: Entry.EntryType = .file,
             compression: CompressionMethod = .none) {
            self.path = path; self.type = type; self.data = data; self.compression = compression
        }
    }
    private let unverified = Data(repeating: 0, count: NS58Constants.firmwareSize)

    @Test func rejectsUnsupportedLocalInputWithoutFollowingLinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = directory.appendingPathComponent(NS58Constants.firmwareName)
        try unverified.write(to: regular)
        let link = directory.appendingPathComponent("linked.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        for url in [link, directory.appendingPathComponent("folder.zip", isDirectory: true)] {
            if url.hasDirectoryPath { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            #expect(throws: (any Error).self) { try SupportedFirmware.importFirmware(from: url) }
        }
        #expect(throws: (any Error).self) {
            try SupportedFirmware.importFirmware(from: URL(string: "https://example.com/file.zip")!)
        }
        let unsupported = directory.appendingPathComponent("file.txt")
        try unverified.write(to: unsupported)
        #expect(throws: (any Error).self) { try SupportedFirmware.importFirmware(from: unsupported) }
    }

    @Test func rejectsOversizedAndHTMLFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download.zip")
        for data in [Data("<html>Download verification</html>".utf8), Data(repeating: 0, count: SupportedFirmware.maxArchiveBytes + 1)] {
            try data.write(to: url)
            #expect(throws: (any Error).self) { try SupportedFirmware.importFirmware(from: url) }
        }
    }

    @Test(arguments: ["../", "/", "C:/", "folder/../", "folder\\", "folder//", "./"])
    func rejectsUnsafeArchivePaths(_ prefix: String) throws {
        let zip = try archive([Item(prefix + NS58Constants.firmwareName, unverified)])
        try expectZIPFailure(zip, containing: "unsafe entry path")
    }

    @Test func rejectsArchiveSymlinkAndAmbiguousTargets() throws {
        let symlink = try archive([Item(NS58Constants.firmwareName, Data("target.bin".utf8), type: .symlink)])
        try expectZIPFailure(symlink, containing: "symbolic links")
        let duplicated = try archive([
            Item(NS58Constants.firmwareName, unverified),
            Item("another/" + NS58Constants.firmwareName, unverified),
        ])
        try expectZIPFailure(duplicated, containing: "more than one expected")
        let deeplyNested = try archive([Item("one/two/" + NS58Constants.firmwareName, unverified)])
        try expectZIPFailure(deeplyNested, containing: "one ordinary folder deep")
    }

    @Test func rejectsExcessEntriesAndDeclaredExpansion() throws {
        let many = try archive((0..<65).map { Item("note-\($0).txt") })
        try expectZIPFailure(many, containing: "too many")
        let large = try archive([
            Item(NS58Constants.firmwareName, unverified),
            Item("oversized.txt", Data(repeating: 0, count: 1024 * 1024), compression: .deflate),
        ])
        #expect(large.count < SupportedFirmware.maxArchiveBytes)
        try expectZIPFailure(large, containing: "declared expansion")
    }

    @Test func rejectsPayloadHashAndCRCChanges() throws {
        let original = try archive([Item(NS58Constants.firmwareName, unverified)])
        try expectZIPFailure(original, containing: "firmware SHA-256")
        var corrupted = original
        let payloadOffset = 30 + NS58Constants.firmwareName.utf8.count
        corrupted[payloadOffset] ^= 1
        try expectZIPFailure(corrupted, containing: "CRC mismatch")
    }

    @Test func rejectsIncompleteCentralDirectory() throws {
        var zip = try archive([Item(NS58Constants.firmwareName, unverified)])
        // Claim a second entry in both ordinary footer count fields without
        // supplying it. Iteration must not silently accept the valid first one.
        let footer = zip.count - 22
        zip[footer + 8] = 2
        zip[footer + 10] = 2
        try expectZIPFailure(zip, containing: "central directory")
    }

    @Test func rejectsUnixSpecialFileEntries() throws {
        var zip = try archive([Item(NS58Constants.firmwareName, unverified)])
        let record = try #require(zip.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        // Unix creator, S_IFIFO in the upper 16-bit mode. ZIPFoundation falls
        // back to .file for this mode; manual imports must not accept it.
        zip[record + 5] = 3
        zip[record + 40] = 0
        zip[record + 41] = 0x10
        try expectZIPFailure(zip, containing: "special file entries")
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"] != nil,
        "Requires NS58_TEST_FIRMWARE with the verified V3.7 BIN"
    ))
    func importsKnownBINAndRepackedZIPsWithoutChangingMirrorPin() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"])
        let originalURL = URL(fileURLWithPath: path)
        let firmware = try Data(contentsOf: originalURL)
        #expect(try SupportedFirmware.importFirmware(from: originalURL) == firmware)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for prefix in ["", "Official NS58 Release/"] {
            var items = [Item(prefix + NS58Constants.firmwareName, firmware), Item(prefix + "Read me.txt", Data("Repacked instructions".utf8))]
            if !prefix.isEmpty { items.insert(Item(prefix, type: .directory), at: 0) }
            let zip = try archive(items)
            #expect(NS58FAT12.sha256(zip) != SupportedFirmware.archiveSHA256)
            let input = directory.appendingPathComponent("user-download.zip")
            try zip.write(to: input)
            #expect(try SupportedFirmware.importFirmware(from: input) == firmware)
            #expect(throws: (any Error).self) { try SupportedFirmware.extract(from: zip) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["user-download.zip"])
        }
        let wrongName = directory.appendingPathComponent("NS59_Elves2_PRO_V3.7.bin")
        try firmware.write(to: wrongName)
        #expect(throws: (any Error).self) { try SupportedFirmware.importFirmware(from: wrongName) }
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_ARCHIVE"] != nil,
        "Requires NS58_TEST_ARCHIVE with the verified official V3.7 ZIP"
    ))
    func importsOriginalOfficialZIP() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NS58_TEST_ARCHIVE"])
        let firmware = try SupportedFirmware.importFirmware(from: URL(fileURLWithPath: path))
        try NS58FAT12.verifyFirmware(firmware, filename: NS58Constants.firmwareName)
    }

    private func archive(_ items: [Item]) throws -> Data {
        let zip = try Archive(accessMode: .create)
        for item in items {
            try zip.addEntry(with: item.path, type: item.type, uncompressedSize: Int64(item.data.count),
                compressionMethod: item.compression) { position, size in
                item.data.subdata(in: Int(position)..<min(Int(position) + size, item.data.count))
            }
        }
        return try #require(zip.data)
    }
    private func expectZIPFailure(_ zip: Data, containing message: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.zip")
        try zip.write(to: url)
        do {
            _ = try SupportedFirmware.importFirmware(from: url)
            Issue.record("Import should reject \(message)")
        } catch {
            #expect(String(describing: error).contains(message))
        }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-import-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
