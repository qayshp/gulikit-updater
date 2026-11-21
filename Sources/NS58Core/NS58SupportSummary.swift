import Foundation

/// A shareable, in-memory snapshot. Construct it from typed state, never by
/// redacting the raw log, labels, error messages, or firmware source paths.
public struct NS58SupportSummary: Sendable {
    public enum Activity: String, Sendable {
        case idle, inspecting, releasing, installing, preparingFirmware
    }

    public enum Event: Sendable {
        case listenerRegistered, listenerFailed
        case accessoryChanged(assigned: Bool, registryPresent: Bool, activity: Activity)
        case inspectionStarted(resetRequested: Bool)
        case exclusiveClaimGranted, inspectionPassed, inspectionFailed
        case recoveryRequired(NS58USBSessionSafety.Reason)
        case writesAcknowledged, updateObservation(registryDisappeared: Bool), installFailed

        fileprivate var text: String {
            switch self {
            case .listenerRegistered: "USB listener registered"
            case .listenerFailed: "USB listener registration failed"
            case let .accessoryChanged(assigned, present, activity):
                "USB accessory \(assigned ? "attached" : "detached") during \(activity.rawValue); physical registry entry present: \(Self.yesNo(present))"
            case let .inspectionStarted(reset):
                reset ? "One-shot transport reset and inspection requested" : "Read-only inspection requested"
            case .exclusiveClaimGranted: "Exclusive USB claim granted"
            case .inspectionPassed: "Read-only inspection passed"
            case .inspectionFailed: "USB inspection failed"
            case let .recoveryRequired(reason): "Fresh USB session required: \(reason.rawValue)"
            case .writesAcknowledged: "Both firmware transaction writes acknowledged"
            case let .updateObservation(disappeared):
                "Physical USB disappearance observed after writes: \(Self.yesNo(disappeared)) (not proof of flashing)"
            case .installFailed: "Install attempt failed; update unconfirmed"
            }
        }

        private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
    }

    public struct History: Sendable {
        static let limit = 20
        public private(set) var events: [Event] = []

        public init() {}

        public mutating func record(_ event: Event) {
            if events.count == Self.limit { events.removeFirst() }
            events.append(event)
        }
    }

    public enum Inspection: Sendable {
        case none
        case passed(version: String?, baselineMatched: Bool)
    }

    public static func render(os: OperatingSystemVersion, appVersion: String?, build: String?,
        candidateCount: Int, activity: Activity, inspection: Inspection,
        modelConfirmed: Bool, firmwareVerified: Bool, installEnabled: Bool,
        recoveryReason: NS58USBSessionSafety.Reason?, history: History) -> String {
        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
        var lines = [
            "GuliKit Updater support summary (v1)",
            "App: \(numericVersion(appVersion)) (build \(numericVersion(build)))",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Target profile: Elves 2 NS58 (not automatic model identification)",
            "Matching candidates: \(candidateCount)",
            "Activity: \(activity.rawValue)",
        ]
        switch inspection {
        case .none:
            lines.append("Active inspection: none")
        case let .passed(version, baselineMatched):
            lines += ["Active inspection: passed", "Reported installed version: \(numericVersion(version))",
                "Strict FAT12 baseline matched: \(yesNo(baselineMatched))"]
        }
        lines += [
            "Physical NS58 model confirmed: \(yesNo(modelConfirmed))",
            "Verified V3.7 firmware staged: \(yesNo(firmwareVerified))",
            "Install action enabled: \(yesNo(installEnabled))",
            "Current candidate recovery gate: \(recoveryReason?.rawValue ?? "none")",
            "", "Recent USB events (oldest first):",
        ]
        if history.events.isEmpty { lines.append("- None recorded") }
        else { lines += history.events.map { "- \($0.text)" } }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func numericVersion(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 24,
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) }
              }) else { return "unknown" }
        return value
    }
}
