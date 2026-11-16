import AppKit
import AccessoryAccess
import IOKit
@preconcurrency import IOUSBHost
import AccessoryReproCore
import OSLog

#if FLASH_DRIVE_REPRO
private let logSubsystem = "com.qayshp.USBFlashDriveRepro"
private let appTitle = "USB Flash Drive Repro"
private let recoveryInstructions = "Stop this run. Quit the repro, return the drive to this Mac and safely eject any mounted volumes before reconnecting for a new test."
#else
private let logSubsystem = "com.qayshp.GuliKitAccessoryRepro"
private let appTitle = "AccessoryAccess Repro"
private let recoveryInstructions = "Use rear OFF, then Setting + Home; reassign a fresh registry session."
#endif
private let events = Logger(subsystem: logSubsystem, category: "accessory-events")
private let operations = Logger(subsystem: logSubsystem, category: "reproduction")

private struct Client: @unchecked Sendable {
    let accessory: AAUSBAccessory
    let device: IOUSBHostDevice
    let traceID: UUID
}

private final class Listener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private func deliver(_ accessory: AAUSBAccessory, connected: Bool) {
        lock.lock()
        sequence &+= 1
        let number = sequence
        let uptime = ProcessInfo.processInfo.systemUptime
        events.notice("Callback #\(number) connected=\(connected) registry=\(accessory.registryID) sourceUptime=\(uptime)")
        DispatchQueue.main.async {
            ReproApp.shared.event(accessory, connected: connected, sequence: number, sourceUptime: uptime)
        }
        lock.unlock()
    }
    nonisolated func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) { deliver(accessory, connected: true) }
    nonisolated func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) { deliver(accessory, connected: false) }
}

@MainActor
private final class ReproApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = ReproApp()
    private let listener = Listener()
    private var state = ReproState()
    private var candidates: [UInt64: AAUSBAccessory] = [:]
    private var client: Client?
    private weak var lastClosedDevice: IOUSBHostDevice?
    private var inFlight = false
    private var registering = true
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "")
    private let logView = NSTextView()
    private let claimButton = NSButton(title: "1. Claim Once", target: nil, action: nil)
    private let closeButton = NSButton(title: "2. Close Once", target: nil, action: nil)
    private let reopenButton = NSButton(title: "3. Reopen Once", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Log", target: nil, action: nil)
    #if FLASH_DRIVE_REPRO
    private var targetGate = FlashDriveTargetGate()
    private let targetLabel = NSTextField(wrappingLabelWithString: "No flash drive assigned.")
    private let spareDriveCheck = NSButton(checkboxWithTitle: "This is my spare USB flash drive; no files or other functions are in use.", target: nil, action: nil)
    private let pinButton = NSButton(title: "Use This Drive for One Test", target: nil, action: nil)
    #endif
    private var consoleObservers: [NSObjectProtocol] = []
    private let formatter = ISO8601DateFormatter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit \(appTitle)",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(appTitle) — Close Only / No Storage Commands"
        window.delegate = self
        let title = NSTextField(labelWithString: "AccessoryAccess close / reopen")
        title.font = .boldSystemFont(ofSize: 22)
        #if FLASH_DRIVE_REPRO
        let scope = NSTextField(wrappingLabelWithString:
            "Regular-drive control: matches USB mass-storage BOT interfaces (08/06/50), not proof of flash-drive type. NS58 updater excluded.\n"
            + "CLOSE-ONLY VARIANT: no explicit destroy(), configuration, interface, reset, SCSI, firmware, disk, or filesystem commands.")
        let instructions = NSTextField(wrappingLabelWithString:
            "Use a spare USB flash drive with no important data. Close its files; disconnect other USB storage where practical. "
            + "Assign only that drive to USB Flash Drive Repro in the macOS USB menu. Whole-device handoff can unmount its volumes or interrupt other functions; macOS may perform its own storage I/O. "
            + "Confirm the identity below before one manual numbered cycle. No automatic actions or retries. Keep the Mac unlocked.")
        #else
        let scope = NSTextField(wrappingLabelWithString:
            "Validated-device fingerprint: 33fa:ff02, serial 115411. These are not proven model- or unit-unique identifiers.\n"
            + "CLOSE-ONLY VARIANT: no explicit destroy() calls. No firmware, USB configuration, interface, SCSI, reset, or controller-sector I/O.")
        let instructions = NSTextField(wrappingLabelWithString:
            "Use a fresh update-mode session and assign Gulikit to AccessoryAccess Repro in the USB menu. "
            + "Close the normal updater before assigning here. Click each numbered action once. "
            + "A failure stops this session; rear OFF, then Setting + Home creates the next session. "
            + "Quit closes any final client. Keep the Mac unlocked.")
        #endif
        for (button, action) in [(claimButton, #selector(claimOnce)), (closeButton, #selector(closeOnce)),
            (reopenButton, #selector(reopenOnce)), (copyButton, #selector(copyLog))] {
            button.target = self; button.action = action
        }
        let buttons = NSStackView(views: [claimButton, closeButton, reopenButton, copyButton])
        buttons.spacing = 10
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = logView; scroll.hasVerticalScroller = true
        #if FLASH_DRIVE_REPRO
        spareDriveCheck.target = self; spareDriveCheck.action = #selector(targetConfirmationChanged)
        pinButton.target = self; pinButton.action = #selector(pinTarget)
        let stack = NSStackView(views: [title, scope, instructions, targetLabel, spareDriveCheck, pinButton, status, buttons, scroll])
        #else
        let stack = NSStackView(views: [title, scope, instructions, status, buttons, scroll])
        #endif
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        for label in [scope, instructions, status] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        #if FLASH_DRIVE_REPRO
        targetLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.setContentSize(NSSize(width: 900, height: 820))
        #endif
        window.minSize = NSSize(width: 800, height: 600)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refresh()
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            consoleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) {
                notification in
                events.notice("Console session event \(notification.name.rawValue, privacy: .public) sourceUptime=\(ProcessInfo.processInfo.systemUptime)")
            })
        }
        log("Listener registration START; no automatic claim or USB command. Process \(ProcessInfo.processInfo.processIdentifier).")
        log("Variant: AA close only; no explicit device.destroy(). Reopen additionally waits for the old device weak reference to clear (bounded 2 seconds).")
        Task {
            do {
                #if FLASH_DRIVE_REPRO
                let criteria = AAUSBAccessoryMatchingCriteria(deviceMatchingCriteria: nil,
                    interfaceMatchingCriteria: [.init(interfaceClass: 0x08, interfaceSubClass: 0x06, interfaceProtocol: 0x50)],
                    interfaceMatchingOption: .matchAll)
                log("Flash-drive control listener: interface 08/06/50 only; this does not identify the storage medium. Explicit target pin required before Claim. NS58 33fa:ff02 excluded.")
                #else
                let criteria = AAUSBAccessoryMatchingCriteria(deviceMatchingCriteria: .init(vendorID: 0x33fa, productID: 0xff02))
                #endif
                let existing = try await AAUSBAccessoryManager.shared.registerListener(listener, matchingCriteria: [criteria])
                registering = false
                log("Listener registration PASS; existing accessories=\(existing.count).")
                for accessory in existing { add(accessory) }
                refresh()
            } catch {
                registering = false; state.fail("Listener registration failed: \(error)"); log("STOP: \(error)"); refresh()
            }
        }
    }

    private func physicalPresent(_ registryID: UInt64) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service); return true
    }
    private func serial(_ registryID: UInt64) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
    #if FLASH_DRIVE_REPRO
    private func identity(_ accessory: AAUSBAccessory) -> ReproUSBIdentity? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(accessory.registryID))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let location = IORegistryEntryCreateCFProperty(service, "locationID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        let product = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        return ReproUSBIdentity(registryID: accessory.registryID, deviceDescriptor: accessory.deviceDescriptorData,
            serial: serial(accessory.registryID), location: location?.uint32Value, product: product)
    }
    private func candidateIdentities() -> [ReproUSBIdentity] {
        // A failed identity read must not disappear from the candidate count.
        let identities = candidates.values.compactMap { identity($0) }
        return identities.count == candidates.count ? identities : []
    }
    private func identityDescription(_ value: ReproUSBIdentity) -> String {
        let location = value.location.map { String(format: "0x%08x", $0) } ?? "unavailable"
        return "\(value.product ?? "Product name unavailable") · " + String(format: "%04x:%04x", value.vendorID, value.productID)
            + " · registry \(value.registryID) · serial \(value.serial ?? "not supplied") · location \(location)"
    }
    @objc private func targetConfirmationChanged() { refresh() }
    @objc private func pinTarget() {
        guard !inFlight, !registering, state.canClaim, candidates.count == 1 else { return }
        do {
            try targetGate.confirm(candidateIdentities(), userConfirmedSpareDrive: spareDriveCheck.state == .on)
            log("Target explicitly pinned for this launch: \(identityDescription(targetGate.confirmedIdentity!)). No USB open or storage command sent.")
        } catch { log("Target not pinned: \(error)") }
        refresh()
    }
    #endif
    private func add(_ accessory: AAUSBAccessory) {
        #if FLASH_DRIVE_REPRO
        guard let value = identity(accessory) else {
            targetGate.revoke()
            state.fail("An assigned BOT candidate has unreadable cached identity. This launch is stopped.")
            log("STOP: unreadable assigned candidate cannot be omitted from the safety gate; no USB open or retry.")
            refresh(); return
        }
        if value.isNS58UpdaterProfile {
            if candidates[accessory.registryID] != nil || targetGate.confirmedIdentity?.registryID == accessory.registryID {
                targetGate.revoke()
                state.fail("An existing flash-drive candidate changed to an excluded identity. This launch is stopped.")
                refresh()
            }
            log("Ignored excluded NS58 updater profile."); return
        }
        guard !targetGate.isRevoked else { log("Candidate not accepted: this flash-drive test launch is already stopped."); return }
        log("BOT mass-storage candidate, medium type unverified: \(identityDescription(value)).")
        #else
        let d = accessory.deviceDescriptorData
        guard d.count == 18, d[0] == 18, d[1] == 1,
              d[8] == 0xfa, d[9] == 0x33, d[10] == 0x02, d[11] == 0xff,
              serial(accessory.registryID) == "115411" else {
            log("Ignored candidate: descriptor or validated serial profile did not match."); return
        }
        #endif
        candidates[accessory.registryID] = accessory
        state.attach(registryID: accessory.registryID)
        if candidates.count != 1 { state.fail("Ambiguous accessory set; no automatic selection.") }
        log("Candidate registry=\(accessory.registryID) generation=\(state.generation) phase=\(state.phase.rawValue) configurationBytes=\(accessory.configurationDescriptorData?.count ?? 0).")
    }
    func event(_ accessory: AAUSBAccessory, connected: Bool, sequence: UInt64, sourceUptime: TimeInterval) {
        let delay = (ProcessInfo.processInfo.systemUptime - sourceUptime) * 1000
        log("Callback #\(sequence) \(connected ? "connect" : "disconnect") registry=\(accessory.registryID) deliveryDelayMs=\(String(format: "%.1f", delay)) phase=\(state.phase.rawValue) physicalRegistryPresent=\(physicalPresent(accessory.registryID)).")
        if connected { add(accessory) }
        else {
            let removed = candidates.removeValue(forKey: accessory.registryID)
            guard removed != nil || state.registryID == accessory.registryID else {
                log("Ignored disconnect for an untracked candidate."); return
            }
            state.detach(registryID: accessory.registryID)
            #if FLASH_DRIVE_REPRO
            if targetGate.confirmedIdentity != nil { targetGate.revoke() }
            #endif
            // An in-flight worker owns its client until its final guard. Do not
            // close concurrently with open/close, or turn a disconnect into success.
            if !inFlight, let old = client {
                client = nil; inFlight = true; refresh()
                Task { await cleanup(old); inFlight = false; refresh() }
            }
        }
        refresh()
    }
    private func refresh() {
        var idle = !inFlight && !registering && candidates.count == 1
        #if FLASH_DRIVE_REPRO
        let identities = candidateIdentities()
        let pinned = targetGate.confirmedIdentity != nil
        if pinned, !targetGate.permits(identities), !targetGate.isRevoked {
            targetGate.revoke()
            state.fail("Pinned flash-drive identity changed, disappeared, or became ambiguous. This launch is stopped.")
            log("STOP: flash-drive target pin revoked; no retarget or retry in this launch.")
        }
        spareDriveCheck.isEnabled = !pinned && !targetGate.isRevoked && !inFlight && !registering && state.canClaim && candidates.count == 1
        pinButton.isEnabled = spareDriveCheck.isEnabled && spareDriveCheck.state == .on && identities.count == 1
        if let confirmed = targetGate.confirmedIdentity {
            targetLabel.stringValue = "\(targetGate.isRevoked ? "STOPPED pin" : "Pinned target"): \(identityDescription(confirmed))"
        } else if targetGate.isRevoked {
            targetLabel.stringValue = "STOP: this launch is blocked. No target can be selected or retried."
        } else {
            targetLabel.stringValue = identities.count == 1 ? "Unconfirmed candidate: \(identityDescription(identities[0]))" : "Assign exactly one spare BOT flash drive; candidates: \(candidates.count). No target selected."
        }
        idle = idle && targetGate.permits(identities)
        #endif
        claimButton.isEnabled = idle && state.canClaim
        closeButton.isEnabled = idle && state.canClose
        reopenButton.isEnabled = idle && state.canReopen && lastClosedDevice == nil
        status.stringValue = "State: \(state.phase.rawValue) · generation \(state.generation) · candidates \(candidates.count)"
            + (state.failure.map { "\nSTOP: \($0) No retry. \(recoveryInstructions)" } ?? "")
            + (state.phase == .finished ? "\nAA CLAIM → CLOSE → REOPEN API PASS. No interface/SCSI/storage behavior was tested. Quit to close the final client." : "")
    }
    private func log(_ message: String) {
        operations.notice("\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) uptime=\(String(format: "%.6f", ProcessInfo.processInfo.systemUptime)) \(message)\n"
        logView.textStorage?.append(NSAttributedString(string: line))
        logView.scrollToEndOfDocument(nil)
    }
    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logView.string, forType: .string)
    }
    @objc private func claimOnce() { open(.claim) }
    @objc private func reopenOnce() { open(.reopen) }
    private func open(_ operation: ReproState.Operation) {
        guard !inFlight, !registering, candidates.count == 1,
              let registryID = state.registryID, let accessory = candidates[registryID] else { return }
        #if FLASH_DRIVE_REPRO
        guard targetGate.permits(candidateIdentities()) else {
            targetGate.revoke()
            state.fail("The explicitly pinned flash-drive identity is absent or changed. This launch is stopped.")
            log("STOP: action-time target mismatch revoked the pin. No USB open or retry.")
            refresh()
            return
        }
        #else
        guard serial(registryID) == "115411" else { return }
        #endif
        if operation == .reopen, lastClosedDevice != nil {
            state.fail("Old device wrapper is still retained. Reopen was not attempted; lifetime control is inconclusive.")
            log("STOP: old device weak reference is not clear. No reopen or retry.")
            refresh(); return
        }
        let token: ReproState.Token
        do { token = try state.begin(operation) }
        catch { log("Action rejected: \(error)"); return }
        inFlight = true; refresh()
        log("\(operation.rawValue) START registry=\(registryID) generation=\(token.generation). AA open only; no configuration/interface/SCSI.")
        Task {
            do {
                let device = try await accessory.open(serviceQueue: nil)
                let opened = Client(accessory: accessory, device: device, traceID: UUID())
                var returnedRegistryID: UInt64 = 0
                let identified = IORegistryEntryGetRegistryEntryID(device.ioService, &returnedRegistryID) == KERN_SUCCESS
                let present = physicalPresent(registryID)
                #if FLASH_DRIVE_REPRO
                let targetMatches = targetGate.permits(candidateIdentities())
                #else
                let targetMatches = true
                #endif
                log("\(operation.rawValue) AA open returned trace=\(opened.traceID) physicalRegistryPresent=\(present) pinnedIdentityMatches=\(targetMatches) returnedRegistryID=\(returnedRegistryID) identityRead=\(identified).")
                guard state.complete(token, physicalRegistryPresent: present && identified && targetMatches,
                    returnedRegistryID: returnedRegistryID) else {
                    log("STOP: stale claim result discarded; closing only for cleanup.")
                    await cleanup(opened)
                    inFlight = false; refresh(); return
                }
                client = opened
                log("\(operation.rawValue) PASS trace=\(opened.traceID) generation=\(state.generation).")
            } catch {
                state.fail("\(operation.rawValue) failed: \(error)")
                log("STOP: \(operation.rawValue) failed: \(error). No retry.")
                // Failed open may have partially established framework state.
                do { try await accessory.close(); log("Failed-open cleanup close returned.") }
                catch { log("Failed-open cleanup close ERROR: \(error).") }
            }
            inFlight = false; refresh()
        }
    }
    @objc private func closeOnce() {
        // Capture only the accessory and a copied trace. Capturing Client or
        // IOUSBHostDevice in the polling Task would itself keep the probe alive.
        guard !inFlight, let accessory = client?.accessory, let traceID = client?.traceID else { return }
        let token: ReproState.Token
        do { token = try state.begin(.close) }
        catch { log("Action rejected: \(error)"); return }
        lastClosedDevice = client?.device
        inFlight = true; refresh()
        log("close START trace=\(traceID). AA close only; no explicit destroy().")
        Task {
            do {
                try await accessory.close()
                log("Accessory close returned trace=\(traceID); no explicit destroy() issued.")
                client = nil
                log("Old client strong reference dropped trace=\(traceID).")
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while lastClosedDevice != nil, state.isCurrent(token),
                    ProcessInfo.processInfo.systemUptime < deadline {
                    do { try await Task.sleep(for: .milliseconds(10)) }
                    catch {
                        state.fail("Lifetime observation cancelled; no reopen.")
                        log("STOP: lifetime observation cancelled. No reopen or retry.")
                        break
                    }
                }
                let cleared = lastClosedDevice == nil
                log("Old device weak reference cleared=\(cleared) trace=\(traceID). This does not measure internal framework/kernel cleanup.")
                if state.complete(token, closedClientReleased: cleared) {
                    log("close-only PASS; old device weak reference cleared. Reopen remains explicit.")
                } else {
                    log("STOP: close-only control did not complete or attachment changed. No reopen.")
                }
            } catch {
                client = nil
                state.fail("close failed: \(error)")
                log("STOP: close failed: \(error). No reopen.")
                log("Failed-close strong reference dropped; no explicit destroy() or retry.")
            }
            inFlight = false; refresh()
        }
    }
    private func cleanup(_ opened: Client) async {
        do { try await opened.accessory.close(); log("Cleanup close returned trace=\(opened.traceID).") }
        catch { log("Cleanup close ERROR trace=\(opened.traceID): \(error).") }
        log("Cleanup close-only scope ending trace=\(opened.traceID); no explicit destroy().")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !inFlight && !registering else {
            log("Window close blocked until the in-flight callback/cleanup finishes.")
            NSSound.beep(); return false
        }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if inFlight || registering {
            let alert = NSAlert()
            alert.messageText = "Wait for AccessoryAccess to finish"
            alert.informativeText = "No storage commands are in use. Allow the current open/close or registration callback to finish before quitting."
            alert.addButton(withTitle: "Keep Waiting"); alert.runModal()
            return .terminateCancel
        }
        guard let opened = client else { return .terminateNow }
        client = nil; inFlight = true; refresh()
        Task {
            await cleanup(opened)
            inFlight = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
private enum ReproMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ReproApp.shared
        application.delegate = delegate
        application.run()
    }
}
