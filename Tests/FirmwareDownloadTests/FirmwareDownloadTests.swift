import Foundation
import Testing
import FirmwareDownload
import NS58Core

struct FirmwareDownloadTests {
    private let mirror = "https://fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip"

    @Test
    func permitsOnlyPinnedHTTPSDownload() throws {
        #expect(SupportedFirmware.isAllowedDownloadURL(try #require(URL(string: mirror))))
        #expect(SupportedFirmware.isAllowedDownloadURL(try #require(URL(string:
            "https://fichiers.touslesdrivers.com:443/84388/NS58_Elves2_V3.7.zip"))))
        let rejected = [
            "http://fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip",
            "https://example.com/84388/NS58_Elves2_V3.7.zip",
            "https://fichiers.touslesdrivers.com.example.com/84388/NS58_Elves2_V3.7.zip",
            "https://user@fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip",
            "https://user:password@fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip",
            "https://fichiers.touslesdrivers.com:8443/84388/NS58_Elves2_V3.7.zip",
            "https://fichiers.touslesdrivers.com/84388/NS59_Elves2_PRO_V3.7.zip",
            "https://fichiers.touslesdrivers.com/82721/NS58_Elves2_V2.9.zip",
            "https://fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip?other=1",
            "https://fichiers.touslesdrivers.com/84388/NS58_Elves2_V3.7.zip#other",
            "file:///tmp/NS58_Elves2_V3.7.zip",
        ]
        for text in rejected {
            #expect(!SupportedFirmware.isAllowedDownloadURL(try #require(URL(string: text))))
        }
    }

    @Test
    func rejectsHTMLAndTruncatedArchives() {
        for bytes in [
            Data(),
            Data("<html><body>429 Too Many Requests</body></html>".utf8),
            Data([0x50, 0x4b, 0x03, 0x04]),
        ] {
            #expect(throws: (any Error).self) {
                try SupportedFirmware.extract(from: bytes)
            }
        }
    }

    @Test
    func rejectsOversizedArchive() {
        let bytes = Data(repeating: 0, count: SupportedFirmware.maxArchiveBytes + 1)
        #expect(throws: (any Error).self) {
            try SupportedFirmware.extract(from: bytes)
        }
    }

    @Test
    func doesNotPublishModifiedFirmware() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modified = Data(repeating: 0, count: NS58Constants.firmwareSize)
        #expect(throws: (any Error).self) {
            try SupportedFirmware.saveVerified(modified, in: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_ARCHIVE"] != nil,
        "Requires NS58_TEST_ARCHIVE with the pinned V3.7 ZIP"
    ))
    func extractsPinnedReleaseAndRejectsArchiveTampering() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NS58_TEST_ARCHIVE"])
        let archive = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(NS58FAT12.sha256(archive) == SupportedFirmware.archiveSHA256)
        let firmware = try SupportedFirmware.extract(from: archive)
        try NS58FAT12.verifyFirmware(firmware, filename: NS58Constants.firmwareName)

        var changed = archive
        try #require(!changed.isEmpty)
        changed[changed.count / 2] ^= 1
        #expect(throws: (any Error).self) {
            try SupportedFirmware.extract(from: changed)
        }
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"] != nil,
        "Requires NS58_TEST_FIRMWARE with the verified V3.7 BIN"
    ))
    func publishesVerifiedFirmwareUsingFixedName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firmware = try firmwareFixture()
        let result = try SupportedFirmware.saveVerified(firmware, in: directory)
        #expect(result.lastPathComponent == NS58Constants.firmwareName)
        #expect(result.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(try Data(contentsOf: result) == firmware)
        #expect(throws: (any Error).self) {
            try SupportedFirmware.saveVerified(firmware, in: directory)
        }
        #expect(try Data(contentsOf: result) == firmware)
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"] != nil,
        "Requires NS58_TEST_FIRMWARE with the verified V3.7 BIN"
    ))
    func preservesExistingFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent(NS58Constants.firmwareName)
        let original = Data("existing user file".utf8)
        try original.write(to: destination)
        #expect(throws: (any Error).self) {
            try SupportedFirmware.saveVerified(firmwareFixture(), in: directory)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [NS58Constants.firmwareName])
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"] != nil,
        "Requires NS58_TEST_FIRMWARE with the verified V3.7 BIN"
    ))
    func preservesSymlinkAndItsTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("existing.bin")
        let link = directory.appendingPathComponent(NS58Constants.firmwareName)
        let original = Data("protected target file".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try SupportedFirmware.saveVerified(firmwareFixture(), in: directory)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try Data(contentsOf: target) == original)
    }

    private func firmwareFixture() throws -> Data {
        let path = try #require(ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"])
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-download-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
