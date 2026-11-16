import Foundation

/// A cached USB/IORegistry identity, never obtained through storage commands.
/// Registry IDs pin one attachment, not a persistent or model-unique identity.
public struct ReproUSBIdentity: Equatable, Sendable {
    public let registryID: UInt64
    public let deviceDescriptor: Data
    public let serial: String?
    public let location: UInt32?
    public let product: String?

    public init?(registryID: UInt64, deviceDescriptor: Data, serial: String?, location: UInt32?, product: String? = nil) {
        let bytes = Array(deviceDescriptor)
        guard registryID != 0, bytes.count == 18, bytes[0] == 18, bytes[1] == 1 else { return nil }
        self.registryID = registryID
        self.deviceDescriptor = Data(bytes)
        self.serial = serial
        self.location = location
        self.product = product
    }

    public var vendorID: UInt16 { UInt16(deviceDescriptor[8]) | UInt16(deviceDescriptor[9]) << 8 }
    public var productID: UInt16 { UInt16(deviceDescriptor[10]) | UInt16(deviceDescriptor[11]) << 8 }
    public var isNS58UpdaterProfile: Bool { vendorID == 0x33fa && productID == 0xff02 }
}

/// One explicit pin per app launch. A replacement or logical reconnect cannot
/// silently become the target. ReproState separately enforces the one-shot cycle.
public struct FlashDriveTargetGate: Sendable {
    public private(set) var confirmedIdentity: ReproUSBIdentity?
    public private(set) var isRevoked = false
    public init() {}

    public mutating func confirm(_ candidates: [ReproUSBIdentity], userConfirmedSpareDrive: Bool) throws {
        guard confirmedIdentity == nil, !isRevoked else { throw ReproError.invalidTransition("A target is already pinned or this launch has been stopped.") }
        guard userConfirmedSpareDrive, candidates.count == 1, let candidate = candidates.first,
              !candidate.isNS58UpdaterProfile else {
            throw ReproError.invalidTransition("Confirm exactly one spare flash drive; the NS58 updater is excluded.")
        }
        confirmedIdentity = candidate
    }

    public func permits(_ candidates: [ReproUSBIdentity]) -> Bool {
        guard !isRevoked, candidates.count == 1, let confirmedIdentity else { return false }
        return candidates[0] == confirmedIdentity && !confirmedIdentity.isNS58UpdaterProfile
    }

    public mutating func revoke() { isRevoked = true }
}
