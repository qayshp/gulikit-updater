import Foundation
import Testing
@testable import NS58Core

struct NS58CoreTests {
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
    func buildsProvenLinuxSequenceWhenFixtureIsAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["NS58_TEST_FIRMWARE"],
              let rootPath =
                ProcessInfo.processInfo.environment["NS58_TEST_LINUX_ROOT"]
        else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let firmware = try Data(contentsOf: url)
        let capturedRoot = try Data(
            contentsOf: URL(fileURLWithPath: rootPath)
        )
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
