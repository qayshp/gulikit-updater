import Foundation

/// Identifies an attachment lifetime independently of the device's registry ID.
///
/// A USB accessory can detach from an app and attach again without receiving a
/// different physical registry ID. Capture the generation before asynchronous
/// work, then use `isCurrent` before publishing that work's result.
public struct NS58AttachmentTracker: Sendable {
    private var generations: [UInt64: UUID] = [:]

    public init() {}

    /// Returns the existing generation for duplicate connect notifications.
    @discardableResult
    public mutating func attach(registryID: UInt64) -> UUID {
        if let existing = generations[registryID] {
            return existing
        }
        let generation = UUID()
        generations[registryID] = generation
        return generation
    }

    /// Invalidates all previously captured work for this attachment lifetime.
    public mutating func detach(registryID: UInt64) {
        generations.removeValue(forKey: registryID)
    }

    public func isCurrent(registryID: UInt64, generation: UUID) -> Bool {
        generations[registryID] == generation
    }

    public func generation(for registryID: UInt64) -> UUID? {
        generations[registryID]
    }
}
