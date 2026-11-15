import Foundation
import Testing
import USBTransport

struct USBTransportTests {
    private let tag: UInt32 = 0x1234_ABCD

    @Test
    func acceptsExactCapacityPayload() throws {
        let capacity = Data([0, 0, 0, 118, 0, 0, 16, 0])
        #expect(try GUBOTResponse.capacityPayload(from: capacity, expectedTag: tag) == capacity)
    }

    @Test
    func doesNotMistakeCapacityPrefixForCSW() throws {
        let capacity = Data(Array("USBS".utf8) + [0, 0, 16, 0])
        #expect(try GUBOTResponse.capacityPayload(from: capacity, expectedTag: tag) == capacity)
    }

    @Test
    func rejectsPrematureCSWEvenWhenStatusIsSuccess() {
        expectFailure(code: 15, containing: "status=0 residue=0") {
            _ = try GUBOTResponse.capacityPayload(from: csw(), expectedTag: tag)
        }
    }

    @Test
    func reportsPrematureFailedCSWWithResidue() {
        expectFailure(code: 15, containing: "status=1 residue=8") {
            _ = try GUBOTResponse.capacityPayload(from: csw(residue: 8, status: 1), expectedTag: tag)
        }
    }

    @Test
    func reportsPrematurePhaseErrorWithoutAcceptingCapacity() {
        expectFailure(code: 15, containing: "status=2 residue=4294967295") {
            _ = try GUBOTResponse.capacityPayload(from: csw(residue: .max, status: 2), expectedTag: tag)
        }
    }

    @Test
    func rejectsImpossibleCapacityResidue() {
        expectFailure(code: 14, containing: "residue=9") {
            _ = try GUBOTResponse.capacityPayload(from: csw(residue: 9, status: 1), expectedTag: tag)
        }
    }

    @Test
    func rejectsPrematureCSWWithWrongTag() {
        expectFailure(code: 12, containing: "CSW tag mismatch") {
            _ = try GUBOTResponse.capacityPayload(from: csw(tag: tag + 1), expectedTag: tag)
        }
    }

    @Test
    func rejectsZeroFilledCSW() {
        expectFailure(code: 11, containing: "Invalid CSW signature") {
            _ = try GUBOTResponse.capacityPayload(from: Data(repeating: 0, count: 13), expectedTag: tag)
        }
    }

    @Test(arguments: [0, 1, 7, 9, 12, 14, 21, 64, 65, 1_000])
    func rejectsOtherCapacityPacketLengths(length: Int) {
        expectFailure(code: 10, containing: "requires exactly 8") {
            _ = try GUBOTResponse.capacityPayload(from: Data(repeating: 0, count: length), expectedTag: tag)
        }
    }

    @Test
    func validatesSuccessfulCSW() throws {
        try GUBOTResponse.validateCSW(csw(), expectedTag: tag)
    }

    @Test(arguments: [0, 1, 8, 12, 14, 64])
    func rejectsWrongCSWLength(length: Int) {
        expectFailure(code: 10, containing: "exactly 13") {
            try GUBOTResponse.validateCSW(Data(repeating: 0, count: length), expectedTag: tag)
        }
    }

    @Test
    func rejectsWrongCSWSignature() {
        var packet = csw()
        packet[0] = 0
        expectFailure(code: 11, containing: "Invalid CSW signature") {
            try GUBOTResponse.validateCSW(packet, expectedTag: tag)
        }
    }

    @Test
    func rejectsWrongCSWTag() {
        expectFailure(code: 12, containing: "CSW tag mismatch") {
            try GUBOTResponse.validateCSW(csw(tag: tag + 1), expectedTag: tag)
        }
    }

    @Test
    func rejectsNonzeroCSWResidue() {
        expectFailure(code: 16, containing: "residue=1") {
            try GUBOTResponse.validateCSW(csw(residue: 1), expectedTag: tag)
        }
    }

    @Test(arguments: [UInt8(1), 2])
    func rejectsFailedAndPhaseErrorCSW(status: UInt8) {
        expectFailure(code: 17, containing: "status=\(status)") {
            try GUBOTResponse.validateCSW(csw(status: status), expectedTag: tag)
        }
    }

    @Test(arguments: [UInt8(3), 255])
    func rejectsReservedStatus(status: UInt8) {
        expectFailure(code: 13, containing: "Invalid CSW status") {
            try GUBOTResponse.validateCSW(csw(status: status), expectedTag: tag)
        }
        expectFailure(code: 13, containing: "Invalid CSW status") {
            _ = try GUBOTResponse.capacityPayload(from: csw(status: status), expectedTag: tag)
        }
    }

    @Test
    func boundsPacketDiagnosticHexTo64Bytes() {
        let packet = Data(repeating: 0xAB, count: 1_000_000)
        let dump = GUBOTResponse.boundedHexDump(packet)
        #expect(dump.components(separatedBy: "ab").count - 1 == 64)
        #expect(dump.contains("1000000 bytes total; first 64 shown"))
        #expect(dump.count < 300)
        #expect(GUBOTResponse.boundedHexDump(Data()) == "<empty>")
        #expect(GUBOTResponse.boundedHexDump(Data([0, 0xAF, 0xFF])) == "00 af ff")
    }

    private func csw(tag: UInt32? = nil, residue: UInt32 = 0, status: UInt8 = 0) -> Data {
        var result = Data("USBS".utf8)
        for value in [tag ?? self.tag, residue] {
            result.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        result.append(status)
        return result
    }

    private func expectFailure(code: Int, containing message: String,
                               operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected a BOT response parsing failure")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == "GuliKitBOTResponse")
            #expect(failure.code == code)
            #expect(failure.localizedDescription.contains(message))
        }
    }
}
