import Darwin
import Foundation
import Testing
@testable import NS58Core

struct NS58CoreTests {
    @Test(arguments: [
        NS58SavedImage.minimumPlanByteCount,
        NS58Constants.reportedDeviceBytes,
        NS58SavedImage.maximumByteCount,
    ])
    func savedImagePassesOfflineBaselineForSupportedLengths(_ length: Int) throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("saved.img")
            var bytes = makeBaseline()
            if length <= bytes.count {
                bytes = Data(bytes.prefix(length))
            } else {
                bytes.append(Data(repeating: 0, count: length - bytes.count))
            }
            try bytes.write(to: url)
            let image = try NS58SavedImage(contentsOf: url)
            let inspection = try image.inspect()
            #expect(image.bytes == bytes)
            #expect(inspection.version.version == "3.7")
            #expect(inspection.baseline == .matching)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test(arguments: ["2.5", "3.8", "4.0"])
    func savedImageDistinguishesReportedVersionFromPlanCompatibility(_ version: String) throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("saved.img")
            let root = NS58Constants.rootDirectoryLBA * NS58Constants.bytesPerSector
            var bytes = makeBaseline()
            bytes.replaceSubrange(root..<(root + 11), with: Array("GuliKit \(version)".utf8))
            try bytes.write(to: url)
            let inspection = try NS58SavedImage(contentsOf: url).inspect()
            #expect(inspection.version.version == version)
            #expect(inspection.baseline == .rejected(reason: "root volume label is not GuliKit 3.7"))
        }
    }

    @Test
    func savedImageCanReportMatchingMetadataInShortRootCapture() throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("root.img")
            let rootEnd = (NS58Constants.rootDirectoryLBA + 4) * NS58Constants.bytesPerSector
            try Data(makeBaseline().prefix(rootEnd)).write(to: url)
            let inspection = try NS58SavedImage(contentsOf: url).inspect()
            #expect(inspection.version.version == "3.7")
            #expect(inspection.baseline == .tooShort(requiredBytes: NS58SavedImage.minimumPlanByteCount))
        }
    }

    @Test
    func savedImageReportsMetadataMismatchDespiteKnownVersion() throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("saved.img")
            var bytes = makeBaseline()
            bytes[8_192 + 100] = 1
            try bytes.write(to: url)
            let inspection = try NS58SavedImage(contentsOf: url).inspect()
            #expect(inspection.version.version == "3.7")
            #expect(inspection.baseline == .rejected(reason: "baseline FAT copies differ"))
        }
    }

    @Test(arguments: [0, NS58SavedImage.maximumByteCount + 1])
    func savedImageRejectsOutOfBoundsFileSize(_ length: Int) throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("saved.img")
            try Data(repeating: 0, count: length).write(to: url)
            #expect(throws: NS58Error.self) { try NS58SavedImage(contentsOf: url) }
        }
    }

    @Test
    func savedImageRejectsDirectoryPipeAndSymlink() throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("saved.img")
            try makeBaseline().write(to: url)
            let symlink = directory.appendingPathComponent("link.img")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
            let pipe = directory.appendingPathComponent("pipe.img")
            try #require(pipe.withUnsafeFileSystemRepresentation { mkfifo($0, 0o600) == 0 })
            for invalid in [directory, symlink, pipe] {
                #expect(throws: NS58Error.self) { try NS58SavedImage(contentsOf: invalid) }
            }
        }
    }

    @Test
    func savedImageRejectsMalformedRootAtInspection() throws {
        try withImageDirectory { directory in
            let url = directory.appendingPathComponent("saved.img")
            try Data(makeBaseline().prefix(512)).write(to: url)
            let image = try NS58SavedImage(contentsOf: url)
            #expect(throws: NS58Error.self) { try image.inspect() }
        }
    }

    private func withImageDirectory(_ work: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try work(directory)
    }

    @Test
    func rejectsWrongFirmwareIdentity() throws {
        let firmware = Data(repeating: 0, count: NS58Constants.firmwareSize)
        #expect(throws: NS58Error.self) {
            try NS58FAT12.verifyFirmware(
                firmware,
                filename: NS58Constants.firmwareName
            )
        }
    }

    @Test
    func inspectsCapturedGeometryShape() throws {
        let baseline = makeBaseline()
        let inspection = try NS58FAT12.inspectBaseline(baseline)
        #expect(inspection.bytesPerSector == 4_096)
        #expect(inspection.rootEntryCount == 512)
        #expect(inspection.volumeLabel == "GuliKit 3.7")
    }

    @Test
    func rejectsTruncatedBaseline() {
        #expect(throws: NS58Error.self) {
            try NS58FAT12.inspectBaseline(Data(repeating: 0, count: 511))
        }
    }

    @Test
    func rejectsDifferentFATCopies() {
        var baseline = makeBaseline()
        baseline[8_192 + 100] = 1
        #expect(throws: NS58Error.self) {
            try NS58FAT12.inspectBaseline(baseline)
        }
    }

    @Test
    func rejectsOccupiedFirmwareClusters() {
        var baseline = makeBaseline()
        // FAT12 cluster 5 begins in the high nibble of byte 7.
        baseline[4_096 + 7] = 0xFF
        baseline[8_192 + 7] = 0xFF
        #expect(throws: NS58Error.self) {
            try NS58FAT12.inspectBaseline(baseline)
        }
    }

    @Test
    func rejectsOccupiedRootSlot() {
        var baseline = makeBaseline()
        baseline[3 * 4_096 + 128] = 0x41
        #expect(throws: NS58Error.self) {
            try NS58FAT12.inspectBaseline(baseline)
        }
    }

    @Test
    func rejectsTruncatedUpdatedImage() {
        #expect(throws: NS58Error.self) {
            try NS58FAT12.verifyUpdatedImage(
                Data(repeating: 0, count: 16_384),
                firmware: Data(repeating: 0, count: NS58Constants.firmwareSize)
            )
        }
    }

    @Test
    func rejectsOversizedVerificationFirmware() {
        #expect(throws: NS58Error.self) {
            try NS58FAT12.verifyUpdatedImage(
                makeBaseline(),
                firmware: Data(repeating: 0, count: 100_000)
            )
        }
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"] != nil
            && ProcessInfo.processInfo.environment["NS58_TEST_LINUX_ROOT"] != nil,
        "Requires NS58_TEST_FIRMWARE and NS58_TEST_LINUX_ROOT capture fixtures"
    ))
    func buildsProvenLinuxSequenceWhenFixtureIsAvailable() throws {
        let path = try #require(ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"])
        let rootPath = try #require(ProcessInfo.processInfo.environment["NS58_TEST_LINUX_ROOT"])
        let url = URL(fileURLWithPath: path)
        let firmware = try Data(contentsOf: url)
        let capturedRoot = try Data(
            contentsOf: URL(fileURLWithPath: rootPath)
        )
        try #require(capturedRoot.count == NS58Constants.bytesPerSector)
        let plan = try NS58FAT12.makeUpdatePlan(
            baseline: makeBaseline(capturedRoot: capturedRoot),
            firmware: firmware,
            firmwareFilename: url.lastPathComponent,
            timestamp: Date(timeIntervalSince1970: 1_785_125_248)
        )

        #expect(plan.firmwarePayload.count == 53_248)
        #expect(
            NS58FAT12.sha256(plan.firmwarePayload)
                == "736d11cebe8dee76b3f52dbb3d44bac2b189ee8cc8c24951d322bc0ee9c84b17"
        )
        #expect(plan.metadataPayload.count == 12_288)
        let fat1 = plan.metadataPayload.subdata(in: 0..<4_096)
        let fat2 = plan.metadataPayload.subdata(in: 4_096..<8_192)
        #expect(fat1 == fat2)
        #expect(
            NS58FAT12.sha256(fat1)
                == "24b3fbf3d56eb9057f9ee84137aa4352f044d320c704ee4935dc2c710561d0f9"
        )
        let generatedRoot = plan.metadataPayload.subdata(in: 8_192..<12_288)
        let differences = zip(generatedRoot, capturedRoot).enumerated().compactMap {
            index, pair in pair.0 == pair.1 ? nil : index
        }
        let allowedTimestampOffsets = Set([
            205, 206, 207, 208, 210, 214, 215, 216,
        ])
        #expect(Set(differences).isSubset(of: allowedTimestampOffsets))
        try NS58FAT12.verifyUpdatedImage(
            plan.updatedImage,
            firmware: firmware
        )
    }

    private func makeBaseline(capturedRoot: Data? = nil) -> Data {
        var image = Data(
            repeating: 0,
            count: NS58Constants.reportedDeviceBytes
        )

        image[0] = 0xEB
        image[1] = 0x3C
        image[2] = 0x90
        image.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
        put16(&image, 11, 4_096)
        image[13] = 1
        put16(&image, 14, 1)
        image[16] = 2
        put16(&image, 17, 512)
        put16(&image, 19, 123)
        image[21] = 0xF8
        put16(&image, 22, 1)
        image.replaceSubrange(43..<54, with: Array("NO NAME    ".utf8))
        image.replaceSubrange(54..<62, with: Array("FAT12   ".utf8))
        image[510] = 0x55
        image[511] = 0xAA

        let fat = Data(
            [0xF8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F]
                + repeatElement(UInt8(0), count: 4_088)
        )
        image.replaceSubrange(4_096..<8_192, with: fat)
        image.replaceSubrange(8_192..<12_288, with: fat)

        let root = 3 * 4_096
        if let capturedRoot {
            image.replaceSubrange(
                root..<(root + 4_096),
                with: capturedRoot
            )
            image.replaceSubrange(
                (root + 128)..<(root + 224),
                with: repeatElement(UInt8(0), count: 96)
            )
            image[root + 128] = 0
            return image
        }
        image.replaceSubrange(
            root..<(root + 11),
            with: Array("GuliKit 3.7".utf8)
        )
        image[root + 11] = 0x08
        image[root + 32 + 11] = 0x0F
        image[root + 64 + 11] = 0x0F
        image.replaceSubrange(
            (root + 96)..<(root + 107),
            with: Array("SYSTEM~1   ".utf8)
        )
        image[root + 96 + 11] = 0x16
        put16(&image, root + 96 + 26, 2)
        image[root + 128] = 0
        return image
    }

    private func put16(_ data: inout Data, _ offset: Int, _ value: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}
