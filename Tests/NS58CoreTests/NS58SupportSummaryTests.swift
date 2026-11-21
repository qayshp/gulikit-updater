import Foundation
import Testing
@testable import NS58Core

struct NS58SupportSummaryTests {
    private func render(inspection: NS58SupportSummary.Inspection = .none,
        appVersion: String? = "0.1.0", build: String? = "1", history: NS58SupportSummary.History = .init(),
        recoveryReason: NS58USBSessionSafety.Reason? = nil) -> String {
        NS58SupportSummary.render(os: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1),
            appVersion: appVersion, build: build, candidateCount: 0, activity: .idle, inspection: inspection,
            modelConfirmed: false, firmwareVerified: false, installEnabled: false,
            recoveryReason: recoveryReason, history: history)
    }

    @Test func disconnectedStartupShowsNoReadiness() {
        let summary = render()
        #expect(summary.contains("App: 0.1.0 (build 1)"))
        #expect(summary.contains("macOS: 27.2.1"))
        #expect(summary.contains("Matching candidates: 0"))
        #expect(summary.contains("Active inspection: none"))
        #expect(!summary.contains("Reported installed version:"))
        #expect(summary.contains("Install action enabled: no"))
        #expect(summary.contains("- None recorded"))
    }

    @Test func versionObservationAndBaselineAreSeparate() {
        let advisory = render(inspection: .passed(version: "2.5", baselineMatched: false))
        #expect(advisory.contains("Reported installed version: 2.5"))
        #expect(advisory.contains("Strict FAT12 baseline matched: no"))
        let validated = render(inspection: .passed(version: "3.7", baselineMatched: true))
        #expect(validated.contains("Strict FAT12 baseline matched: yes"))
        #expect(validated.contains("Physical NS58 model confirmed: no"))
        #expect(validated.contains("Install action enabled: no"))
    }

    @Test func unstructuredStringsAreNeverIncluded() {
        let summary = render(inspection: .passed(version: "3.7\n/Users/example/private.bin", baselineMatched: false),
            appVersion: "/private/build", build: "")
        #expect(summary.contains("App: unknown (build unknown)"))
        #expect(summary.contains("Reported installed version: unknown"))
        #expect(!summary.contains("/Users/"))
        #expect(!summary.contains("/private/"))
    }

    @Test func observedOwnershipLossSurvivesReconnectAndFailureCleanup() throws {
        var history = NS58SupportSummary.History()
        history.record(.inspectionStarted(resetRequested: false))
        history.record(.exclusiveClaimGranted)
        history.record(.accessoryChanged(assigned: false, registryPresent: true, activity: .inspecting))
        history.record(.recoveryRequired(.ownershipLost))
        history.record(.inspectionFailed)
        history.record(.accessoryChanged(assigned: true, registryPresent: true, activity: .idle))
        let summary = render(history: history, recoveryReason: .inspectionFailed)
        #expect(summary.contains("Current candidate recovery gate: inspectionFailed"))
        let detached = try #require(summary.range(of: "USB accessory detached during inspecting; physical registry entry present: yes"))
        let attached = try #require(summary.range(of: "USB accessory attached during idle; physical registry entry present: yes"))
        #expect(detached.lowerBound < attached.lowerBound)
        #expect(summary.contains("Fresh USB session required: ownershipLost"))
    }

    @Test func historyKeepsNewestTwentyAndDoesNotAssertFlashSuccess() {
        var history = NS58SupportSummary.History()
        history.record(.listenerFailed)
        for _ in 0..<20 { history.record(.listenerRegistered) }
        history.record(.updateObservation(registryDisappeared: true))
        let summary = render(history: history)
        #expect(history.events.count == 20)
        #expect(!summary.contains("registration failed"))
        #expect(summary.hasSuffix("Physical USB disappearance observed after writes: yes (not proof of flashing)\n"))
    }
}
