import Foundation
import Testing
@testable import NS58Core

struct NS58USBSessionSafetyTests {
    @Test func freshCandidateCanInspectButClaimedOrBusyCannot() {
        let safety = NS58USBSessionSafety()
        #expect(safety.canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 1, previouslyWrote: false))
        #expect(!safety.canInspect(registryID: 42, busy: true, hasClaim: false, candidateCount: 1, previouslyWrote: false))
        #expect(!safety.canInspect(registryID: 42, busy: false, hasClaim: true, candidateCount: 1, previouslyWrote: false))
        #expect(!safety.canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 2, previouslyWrote: false))
        #expect(!safety.canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 0, previouslyWrote: false))
    }

    @Test(arguments: [NS58USBSessionSafety.Reason.inspectionFailed, .ownershipLost, .released, .releaseFailed, .updateAttempted])
    func usbRecoveryGatesBlockOrdinaryAndResetInspection(_ reason: NS58USBSessionSafety.Reason) {
        var safety = NS58USBSessionSafety()
        safety.requireFreshSession(42, reason: reason)
        #expect(!safety.canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 1, previouslyWrote: false))
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: true, hasFirmware: true, modelConfirmed: true, baselineValidated: true, previouslyWrote: false))
    }

    @Test func logicalReattachDoesNotClearPhysicalInstanceBlock() {
        var safety = NS58USBSessionSafety()
        var attachments = NS58AttachmentTracker()
        let before = attachments.attach(registryID: 42)
        safety.requireFreshSession(42, reason: .ownershipLost)
        attachments.detach(registryID: 42)
        let after = attachments.attach(registryID: 42)
        #expect(before != after)
        #expect(safety.reason(for: 42) == .ownershipLost)
        #expect(!safety.canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 1, previouslyWrote: false))
    }

    @Test func newPhysicalInstanceIsEligibleButOldOneStaysBlocked() {
        var safety = NS58USBSessionSafety()
        safety.requireFreshSession(42, reason: .inspectionFailed)
        #expect(safety.canInspect(registryID: 99, busy: false, hasClaim: false, candidateCount: 1, previouslyWrote: false))
        #expect(safety.reason(for: 42) == .inspectionFailed)
        // A late completion/event for the old instance cannot unblock either.
        safety.requireFreshSession(42, reason: .ownershipLost)
        #expect(safety.reason(for: 99) == nil)
        #expect(safety.reason(for: 42) == .ownershipLost)
    }

    @Test func restoredRecoveryStateSurvivesRelaunch() {
        var safety = NS58USBSessionSafety()
        safety.requireFreshSession(42, reason: .releaseFailed)
        let restored = NS58USBSessionSafety(restoring: safety.blockedSessions,
            savedBootSessionID: "boot-a", currentBootSessionID: "boot-a")
        #expect(restored.reason(for: 42) == .releaseFailed)
        #expect(!restored.canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 1, previouslyWrote: false))
    }

    @Test func rebootOrMissingBootIdentityDoesNotReuseOldRegistryQuarantine() {
        let blocked: [UInt64: NS58USBSessionSafety.Reason] = [42: .ownershipLost]
        for boot in ["boot-b", "", nil] {
            let restored = NS58USBSessionSafety(restoring: blocked,
                savedBootSessionID: "boot-a", currentBootSessionID: boot)
            #expect(restored.reason(for: 42) == nil)
        }
    }

    @Test func consumedWriteCannotBeWeakenedByReleaseOrLogicalEvents() {
        var safety = NS58USBSessionSafety()
        safety.requireFreshSession(42, reason: .updateAttempted)
        safety.requireFreshSession(42, reason: .released)
        safety.requireFreshSession(42, reason: .ownershipLost)
        #expect(safety.reason(for: 42) == .updateAttempted)
        #expect(!NS58USBSessionSafety().canInspect(registryID: 42, busy: false, hasClaim: false, candidateCount: 1, previouslyWrote: true))
    }

    @Test func installationRequiresPhysicalModelConfirmationAndAllOtherGates() {
        let safety = NS58USBSessionSafety()
        #expect(safety.canInstall(registryID: 42, busy: false, hasClaim: true, hasFirmware: true, modelConfirmed: true, baselineValidated: true, previouslyWrote: false))
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: true, hasFirmware: true, modelConfirmed: false, baselineValidated: true, previouslyWrote: false))
        #expect(!safety.canInstall(registryID: 42, busy: true, hasClaim: true, hasFirmware: true, modelConfirmed: true, baselineValidated: true, previouslyWrote: false))
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: false, hasFirmware: true, modelConfirmed: true, baselineValidated: true, previouslyWrote: false))
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: true, hasFirmware: false, modelConfirmed: true, baselineValidated: true, previouslyWrote: false))
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: true, hasFirmware: true, modelConfirmed: true, baselineValidated: true, previouslyWrote: true))
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: true, hasFirmware: true, modelConfirmed: true, baselineValidated: true, previouslyWrote: false, candidateCount: 2))
    }

    @Test func advisoryObservationCannotAuthorizeAnUnvalidatedWriteBaseline() {
        let safety = NS58USBSessionSafety()
        #expect(!safety.canInstall(registryID: 42, busy: false, hasClaim: true,
            hasFirmware: true, modelConfirmed: true, baselineValidated: false, previouslyWrote: false))
    }

    private func descriptor() -> Data {
        Data([18, 1, 0x10, 0x01, 0, 0, 0, 64, 0xfa, 0x33, 0x02, 0xff, 0x10, 0x01, 1, 2, 3, 1])
    }

    @Test func parsesKnownUpdaterDescriptorWithoutClaimingModelIdentity() throws {
        let parsed = try NS58UpdaterDescriptor(validating: descriptor())
        #expect(parsed.deviceRevision == 0x0110)
    }

    @Test func rejectsTruncatedAndExtendedDescriptors() {
        for data in [Data(), Data(descriptor().prefix(17)), descriptor() + Data([0])] {
            #expect(throws: NS58Error.self) { try NS58UpdaterDescriptor(validating: data) }
        }
    }

    @Test(arguments: [0, 1, 8, 9, 10, 11])
    func rejectsMalformedLengthTypeOrWrongUSBIdentity(_ offset: Int) {
        var bytes = descriptor()
        bytes[offset] ^= 0xff
        #expect(throws: NS58Error.self) { try NS58UpdaterDescriptor(validating: bytes) }
    }
}
