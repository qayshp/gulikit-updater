import Foundation
import Testing
import USBTransport

struct GUBOTResetPolicyTests {
    @Test
    func constructsExactNS58ResetRequest() {
        var request = GUBOTResetPolicy.bulkOnlyResetRequest()
        #expect(MemoryLayout.size(ofValue: request) == 8)
        #expect(request.bmRequestType == 0x21)
        #expect(request.bRequest == 0xFF)
        #expect(request.wValue == 0)
        #expect(request.wIndex == 3)
        #expect(request.wLength == 0)
        let bytes = withUnsafeBytes(of: &request) { Array($0) }
        #expect(bytes == [0x21, 0xFF, 0, 0, 3, 0, 0, 0])
    }

    @Test
    func ordersResetThenClearInThenClearOut() {
        #expect(GUBOTResetPolicy.steps.map(\.intValue) == [0, 1, 2])
        #expect(GUBOTResetStep.classReset.rawValue == 0)
        #expect(GUBOTResetStep.clearBulkIn.rawValue == 1)
        #expect(GUBOTResetStep.clearBulkOut.rawValue == 2)
    }

    @Test
    func validBeginConsumesAttemptBeforeCallerIO() throws {
        let policy = GUBOTResetPolicy()
        #expect(!policy.attempted)
        try policy.begin(commandCount: 0, writingStarted: false)
        // No I/O is performed by this test or policy; the reservation alone
        // must consume the sole allowed reset attempt.
        #expect(policy.attempted)
    }

    @Test
    func rejectsSecondAttemptEvenIfFirstIOWouldHaveFailed() throws {
        let policy = GUBOTResetPolicy()
        try policy.begin(commandCount: 0, writingStarted: false)
        expectFailure(code: 1, containing: "already attempted") {
            try policy.begin(commandCount: 0, writingStarted: false)
        }
        #expect(policy.attempted)
    }

    @Test
    func rejectsAfterWritingWithoutConsumingAttempt() throws {
        let policy = GUBOTResetPolicy()
        expectFailure(code: 2, containing: "writing has started") {
            try policy.begin(commandCount: 0, writingStarted: true)
        }
        #expect(!policy.attempted)
        try policy.begin(commandCount: 0, writingStarted: false)
        #expect(policy.attempted)
    }

    @Test(arguments: [UInt32(1), UInt32.max])
    func rejectsAfterAnyCommandWithoutConsumingAttempt(commandCount: UInt32) throws {
        let policy = GUBOTResetPolicy()
        expectFailure(code: 3, containing: "before the first SCSI command") {
            try policy.begin(commandCount: commandCount, writingStarted: false)
        }
        #expect(!policy.attempted)
        try policy.begin(commandCount: 0, writingStarted: false)
        #expect(policy.attempted)
    }

    @Test
    func reportsConsumedAttemptBeforeOtherInvalidConditions() throws {
        let policy = GUBOTResetPolicy()
        try policy.begin(commandCount: 0, writingStarted: false)
        expectFailure(code: 1, containing: "already attempted") {
            try policy.begin(commandCount: 1, writingStarted: true)
        }
    }

    @Test
    func rejectsCombinedWritingAndCommandState() {
        let policy = GUBOTResetPolicy()
        expectFailure(code: 2, containing: "writing has started") {
            try policy.begin(commandCount: 1, writingStarted: true)
        }
        #expect(!policy.attempted)
    }

    private func expectFailure(code: Int, containing message: String,
                               operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected a BOT reset-policy rejection")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == "GuliKitBOTReset")
            #expect(failure.code == code)
            #expect(failure.localizedDescription.contains(message))
        }
    }
}
