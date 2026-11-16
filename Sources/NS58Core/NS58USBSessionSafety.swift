import Foundation

/// These are recovery gates for a physical IORegistry instance, not proof of
/// model identity. A logical AccessoryAccess reconnect may keep the same ID.
public struct NS58USBSessionSafety: Sendable {
    public enum Reason: String, Sendable, Codable {
        case inspectionFailed
        case ownershipLost
        case released
        case releaseFailed
        case updateAttempted

        public var explanation: String {
            switch self {
            case .inspectionFailed: "USB inspection failed."
            case .ownershipLost: "USB ownership changed unexpectedly."
            case .released: "This USB session was released; reuse is not yet reliable."
            case .releaseFailed: "USB release failed after the transport closed."
            case .updateAttempted: "This USB session already attempted an installation."
            }
        }
    }

    public private(set) var blockedSessions: [UInt64: Reason]

    public init(blockedSessions: [UInt64: Reason] = [:]) {
        self.blockedSessions = blockedSessions
    }

    public init(restoring blockedSessions: [UInt64: Reason], savedBootSessionID: String?,
        currentBootSessionID: String?) {
        // IORegistry IDs are scoped to one kernel boot, not durable identities.
        if let currentBootSessionID, !currentBootSessionID.isEmpty,
           savedBootSessionID == currentBootSessionID {
            self.blockedSessions = blockedSessions
        } else {
            self.blockedSessions = [:]
        }
    }

    public mutating func requireFreshSession(_ registryID: UInt64, reason: Reason) {
        // Do not weaken an installation-consumed gate through a later event.
        if blockedSessions[registryID] != .updateAttempted {
            blockedSessions[registryID] = reason
        }
    }

    public func reason(for registryID: UInt64) -> Reason? {
        blockedSessions[registryID]
    }

    public func canInspect(registryID: UInt64, busy: Bool, hasClaim: Bool,
        candidateCount: Int, previouslyWrote: Bool) -> Bool {
        !busy && !hasClaim && candidateCount == 1 && !previouslyWrote
            && reason(for: registryID) == nil
    }

    public func canInstall(registryID: UInt64, busy: Bool, hasClaim: Bool,
        hasFirmware: Bool, modelConfirmed: Bool, previouslyWrote: Bool,
        candidateCount: Int = 1) -> Bool {
        !busy && hasClaim && hasFirmware && modelConfirmed && !previouslyWrote
            && candidateCount == 1 && reason(for: registryID) == nil
    }
}

/// Strict parsing of the updater's USB device descriptor. Matching this
/// fingerprint is not a documented, cross-model NS58 identification protocol.
public struct NS58UpdaterDescriptor: Equatable, Sendable {
    public static let vendorID: UInt16 = 0x33fa
    public static let productID: UInt16 = 0xff02
    public static let validatedSerial = "115411"

    public let deviceRevision: UInt16

    public init(validating data: Data) throws {
        let bytes = Array(data)
        guard bytes.count == 18, bytes[0] == 18, bytes[1] == 1 else {
            throw NS58Error.invalid("Malformed USB device descriptor")
        }
        let vendor = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        let product = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
        guard vendor == Self.vendorID, product == Self.productID else {
            throw NS58Error.invalid("USB vendor/product does not match the validated updater profile")
        }
        deviceRevision = UInt16(bytes[12]) | UInt16(bytes[13]) << 8
    }
}
