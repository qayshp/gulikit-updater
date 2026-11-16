import Foundation

/// An offline-testable one-shot protocol. It contains no USB or filesystem code.
public struct ReproState: Sendable {
    public enum Phase: String, Sendable {
        case waiting, ready, opening, claimed, closing, closed, reopening, finished, recoveryRequired
    }
    public enum Operation: String, Sendable { case claim, close, reopen }
    public struct Token: Sendable, Equatable {
        public let registryID: UInt64
        public let generation: UInt64
        public let operation: Operation
    }
    public private(set) var phase: Phase = .waiting
    public private(set) var registryID: UInt64?
    public private(set) var generation: UInt64 = 0
    public private(set) var failure: String?
    private var blockedIDs: Set<UInt64> = []

    public init() {}

    public var canClaim: Bool { phase == .ready }
    public var canClose: Bool { phase == .claimed }
    public var canReopen: Bool { phase == .closed }
    public var operationInProgress: Bool {
        [.opening, .closing, .reopening].contains(phase)
    }

    public mutating func attach(registryID id: UInt64) {
        guard id != registryID else { return }
        let active = operationInProgress || phase == .claimed || phase == .finished
        if active, let oldID = registryID { blockedIDs.insert(oldID) }
        registryID = id
        generation &+= 1
        if active {
            fail("Attachment changed while an operation or exclusive session was active.")
        } else if blockedIDs.contains(id) {
            phase = .recoveryRequired
        } else {
            phase = .ready
            failure = nil
        }
    }

    public mutating func detach(registryID id: UInt64) {
        guard registryID == id else { return }
        blockedIDs.insert(id)
        generation &+= 1
        registryID = nil
        phase = .recoveryRequired
        failure = "Accessory disconnected. Rear OFF, then Setting + Home; reassign the fresh session."
    }

    public mutating func begin(_ operation: Operation) throws -> Token {
        let permitted = switch operation {
        case .claim: canClaim
        case .close: canClose
        case .reopen: canReopen
        }
        guard permitted, let registryID else {
            throw ReproError.invalidTransition("\(operation.rawValue) is not allowed in \(phase.rawValue).")
        }
        phase = switch operation {
        case .claim: .opening
        case .close: .closing
        case .reopen: .reopening
        }
        return Token(registryID: registryID, generation: generation, operation: operation)
    }

    public func isCurrent(_ token: Token) -> Bool {
        registryID == token.registryID && generation == token.generation && operationInProgress
    }

    @discardableResult
    public mutating func complete(_ token: Token, physicalRegistryPresent: Bool = true,
        returnedRegistryID: UInt64? = nil) -> Bool {
        guard physicalRegistryPresent,
              returnedRegistryID == nil || returnedRegistryID == token.registryID else {
            fail("Physical USB instance disappeared or the returned client identity differs; no pass published.")
            return false
        }
        let expected: Phase = switch token.operation {
        case .claim: .opening
        case .close: .closing
        case .reopen: .reopening
        }
        guard isCurrent(token), phase == expected else {
            fail("Attachment changed during \(token.operation.rawValue); stale result discarded.")
            return false
        }
        phase = switch token.operation {
        case .claim: .claimed
        case .close: .closed
        case .reopen: .finished
        }
        return true
    }

    public mutating func fail(_ message: String) {
        if let registryID { blockedIDs.insert(registryID) }
        phase = .recoveryRequired
        failure = message
    }
}

public enum ReproError: Error, CustomStringConvertible {
    case invalidTransition(String)
    public var description: String {
        switch self { case .invalidTransition(let message): message }
    }
}
