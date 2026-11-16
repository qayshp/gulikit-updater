import Foundation
import Testing
@testable import AccessoryReproCore

@Suite struct FlashDriveTargetTests {
    private func identity(id: UInt64 = 17, vendor: UInt16 = 0x1234, product: UInt16 = 0x5678,
        serial: String? = nil, location: UInt32? = 0x2100000) -> ReproUSBIdentity {
        var descriptor = Data(repeating: 0, count: 18)
        descriptor[0] = 18; descriptor[1] = 1
        descriptor[8] = UInt8(truncatingIfNeeded: vendor); descriptor[9] = UInt8(vendor >> 8)
        descriptor[10] = UInt8(truncatingIfNeeded: product); descriptor[11] = UInt8(product >> 8)
        return ReproUSBIdentity(registryID: id, deviceDescriptor: descriptor, serial: serial, location: location)!
    }

    @Test func rejectsMalformedDescriptorAndMissingRegistry() {
        #expect(ReproUSBIdentity(registryID: 17, deviceDescriptor: Data(repeating: 0, count: 18), serial: nil, location: nil) == nil)
        #expect(ReproUSBIdentity(registryID: 0, deviceDescriptor: identity().deviceDescriptor, serial: nil, location: nil) == nil)
        #expect(ReproUSBIdentity(registryID: 17, deviceDescriptor: Data([18, 1]), serial: nil, location: nil) == nil)
    }

    @Test func requiresExplicitSingleCandidateConfirmation() {
        var gate = FlashDriveTargetGate()
        #expect(!gate.permits([identity()]))
        #expect(throws: ReproError.self) { try gate.confirm([], userConfirmedSpareDrive: true) }
        #expect(throws: ReproError.self) { try gate.confirm([identity(), identity(id: 18)], userConfirmedSpareDrive: true) }
        #expect(throws: ReproError.self) { try gate.confirm([identity()], userConfirmedSpareDrive: false) }
        #expect(gate.confirmedIdentity == nil)
    }

    @Test func excludesKnownControllerEvenWhenConfirmed() {
        var gate = FlashDriveTargetGate()
        #expect(throws: ReproError.self) { try gate.confirm([identity(vendor: 0x33fa, product: 0xff02)], userConfirmedSpareDrive: true) }
        #expect(gate.confirmedIdentity == nil)
    }

    @Test func driveWithoutSerialCanBePinnedButNotReplaced() throws {
        var gate = FlashDriveTargetGate()
        try gate.confirm([identity()], userConfirmedSpareDrive: true)
        #expect(gate.permits([identity()]))
        #expect(!gate.permits([]))
        #expect(!gate.permits([identity(id: 18)]))
        #expect(!gate.permits([identity(), identity(id: 18)]))
        #expect(throws: ReproError.self) { try gate.confirm([identity(id: 18)], userConfirmedSpareDrive: true) }
    }

    @Test func identityChangesFailClosed() throws {
        var gate = FlashDriveTargetGate()
        try gate.confirm([identity(serial: "test-drive")], userConfirmedSpareDrive: true)
        for changed in [identity(vendor: 0x1111, serial: "test-drive"),
            identity(product: 0x2222, serial: "test-drive"), identity(serial: "other"),
            identity(serial: nil), identity(serial: "test-drive", location: nil),
            identity(serial: "test-drive", location: 99)] {
            #expect(!gate.permits([changed]))
        }
    }

    @Test func revocationNeverAllowsSilentReturnOrRepin() throws {
        var gate = FlashDriveTargetGate()
        try gate.confirm([identity()], userConfirmedSpareDrive: true)
        gate.revoke()
        #expect(gate.isRevoked)
        #expect(!gate.permits([identity()]))
        #expect(throws: ReproError.self) { try gate.confirm([identity()], userConfirmedSpareDrive: true) }
    }

    @Test func productSnapshotAlsoStaysPinned() throws {
        let a = ReproUSBIdentity(registryID: 17, deviceDescriptor: identity().deviceDescriptor, serial: nil, location: nil, product: "Spare")!
        let b = ReproUSBIdentity(registryID: 17, deviceDescriptor: a.deviceDescriptor, serial: nil, location: nil, product: "Other")!
        var gate = FlashDriveTargetGate()
        try gate.confirm([a], userConfirmedSpareDrive: true)
        #expect(!gate.permits([b]))
    }
}
