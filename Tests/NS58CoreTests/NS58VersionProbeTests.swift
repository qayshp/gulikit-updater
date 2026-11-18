import Foundation
import Testing
@testable import NS58Core

struct NS58VersionProbeTests {
    @Test(arguments: ["0.9", "2.5", "3.7", "3.8", "4.0", "9.9"])
    func observesOlderSupportedAndNewerDottedVersions(_ version: String) throws {
        let observed = try NS58VersionProbe.inspect(makeImage(label: "GuliKit \(version)"))
        #expect(observed.volumeLabel == "GuliKit \(version)")
        #expect(observed.version == version)
    }

    @Test(arguments: ["NO NAME", "OtherBrand", "gulikit 3.7", "GuliKit 3", "GuliKit 3.", "GuliKit .7", "GuliKit 3-7", "GuliKit 3e7"])
    func preservesReadableUnknownLabelsWithoutGuessingVersion(_ label: String) throws {
        let observed = try NS58VersionProbe.inspect(makeImage(label: label))
        #expect(observed.volumeLabel == label)
        #expect(observed.version == nil)
    }

    @Test
    func probesWithoutApplyingStrictWriterTemplateOrFreeSpaceRequirements() throws {
        var image = makeImage(label: "GuliKit 3.8")
        // A changed boot label, different FAT copies, and occupied firmware
        // clusters are irrelevant to reading one unambiguous root label.
        image.replaceSubrange(43..<54, with: Array("OTHER LABEL".utf8))
        image[4_096 + 7] = 0xFF
        image[8_192 + 7] = 0xAA
        setEntry(&image, index: 1, name: "SOMETHINBIN", attributes: 0x20)
        #expect(try NS58VersionProbe.inspect(image).version == "3.8")
        #expect(throws: NS58Error.self) { try NS58FAT12.inspectBaseline(image) }
    }

    @Test(arguments: ["2.5", "3.8", "4.0"])
    func observingAnotherVersionDoesNotMakeItWriterEligible(_ version: String) throws {
        let image = makeImage(label: "GuliKit \(version)")
        #expect(try NS58VersionProbe.inspect(image).version == version)
        #expect(throws: NS58Error.self) { try NS58FAT12.inspectBaseline(image) }
    }

    @Test
    func scansAllAllocatedRootSectorsAndAllowsAFullRoot() throws {
        var image = makeImage(label: nil)
        for index in 0..<512 {
            setEntry(&image, index: index, name: "ORDINARYBIN", attributes: 0x20)
        }
        setEntry(&image, index: 511, name: "GuliKit 3.7", attributes: 0x08)
        #expect(try NS58VersionProbe.inspect(image).version == "3.7")
    }

    @Test
    func ignoresDeletedAndLongFilenameRecords() throws {
        var image = makeImage(label: nil)
        setEntry(&image, index: 0, name: "OLDLABEL", attributes: 0x08)
        image[3 * 4_096] = 0xE5
        setEntry(&image, index: 1, name: "LFNRECORD", attributes: 0x0F)
        setEntry(&image, index: 2, name: "GuliKit 3.7", attributes: 0x08)
        #expect(try NS58VersionProbe.inspect(image).version == "3.7")
    }

    @Test
    func stopsAtFirstUnallocatedEntry() throws {
        var image = makeImage(label: "GuliKit 3.7")
        // Entry 1 is the end marker, so a stale duplicate at 2 is ignored.
        setEntry(&image, index: 2, name: "GuliKit 3.8", attributes: 0x08)
        #expect(try NS58VersionProbe.inspect(image).version == "3.7")
    }

    @Test
    func rejectsMissingVolumeLabelEvenWhenBootLabelContainsVersion() {
        var image = makeImage(label: nil)
        image.replaceSubrange(43..<54, with: Array("GuliKit 3.7".utf8))
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test
    func rejectsDuplicateAllocatedLabelsEvenIfIdentical() {
        var image = makeImage(label: "GuliKit 3.7")
        setEntry(&image, index: 1, name: "GuliKit 3.7", attributes: 0x08)
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test(arguments: [0x09, 0x18, 0x28, 0x48, 0x88])
    func rejectsMalformedVolumeAttributes(_ attributes: Int) {
        var image = makeImage(label: "GuliKit 3.7")
        image[3 * 4_096 + 11] = UInt8(attributes)
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test(arguments: [20, 21, 26, 27, 28, 29, 30, 31])
    func rejectsVolumeEntriesThatClaimClustersOrFileBytes(_ offset: Int) {
        var image = makeImage(label: "GuliKit 3.7")
        image[3 * 4_096 + offset] = 1
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test(arguments: [0x00, 0x1F, 0x7F, 0x80, 0xFF])
    func rejectsUnreadableLabels(_ byte: Int) {
        var image = makeImage(label: "GuliKit 3.7")
        image[3 * 4_096 + 5] = UInt8(byte)
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test
    func rejectsEmptySpacePaddedLabel() {
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(makeImage(label: "")) }
    }

    @Test(arguments: [0, 1, 510, 511, 512, 12_288, 16_384, 28_671])
    func rejectsTruncatedInputWithoutOutOfBoundsReads(_ length: Int) {
        let image = Data(makeImage(label: "GuliKit 3.7").prefix(length))
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test
    func acceptsExactlyCompleteRootDirectory() throws {
        let image = Data(makeImage(label: "GuliKit 3.7").prefix(28_672))
        #expect(try NS58VersionProbe.inspect(image).version == "3.7")
    }

    @Test
    func handlesDataSliceWithNonzeroStartIndex() throws {
        var padded = Data(repeating: 0xAA, count: 19)
        padded.append(makeImage(label: "GuliKit 3.7"))
        let slice = padded[19...]
        #expect(try NS58VersionProbe.inspect(slice).version == "3.7")
    }

    @Test(arguments: [3, 11, 13, 14, 16, 17, 19, 22, 54, 510, 511])
    func rejectsChangedHeaderOrGeometry(_ offset: Int) {
        var image = makeImage(label: "GuliKit 3.7")
        image[offset] ^= 0x01
        #expect(throws: NS58Error.self) { try NS58VersionProbe.inspect(image) }
    }

    @Test
    func ignoresFakeLabelOutsideDeclaredRootDirectory() throws {
        var image = makeImage(label: "GuliKit 3.7")
        let fake = 7 * 4_096
        image.replaceSubrange(fake..<(fake + 11), with: Array("GuliKit 3.8".utf8))
        image[fake + 11] = 0x08
        #expect(try NS58VersionProbe.inspect(image).version == "3.7")
    }

    private func makeImage(label: String?) -> Data {
        var image = Data(repeating: 0, count: 23 * 4_096)
        image.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
        put16(&image, offset: 11, value: 4_096)
        image[13] = 1
        put16(&image, offset: 14, value: 1)
        image[16] = 2
        put16(&image, offset: 17, value: 512)
        put16(&image, offset: 19, value: 123)
        put16(&image, offset: 22, value: 1)
        image.replaceSubrange(43..<54, with: Array("NO NAME    ".utf8))
        image.replaceSubrange(54..<62, with: Array("FAT12   ".utf8))
        image[510] = 0x55
        image[511] = 0xAA
        if let label { setEntry(&image, index: 0, name: label, attributes: 0x08) }
        return image
    }

    private func setEntry(_ image: inout Data, index: Int, name: String, attributes: UInt8) {
        let start = 3 * 4_096 + index * 32
        let encoded = Array(name.utf8)
        precondition(encoded.count <= 11)
        image.replaceSubrange(start..<(start + 32), with: repeatElement(UInt8(0), count: 32))
        image.replaceSubrange(start..<(start + 11), with: encoded + repeatElement(UInt8(0x20), count: 11 - encoded.count))
        image[start + 11] = attributes
    }

    private func put16(_ image: inout Data, offset: Int, value: Int) {
        image[offset] = UInt8(value & 0xFF)
        image[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}
