import AppKit
import AccessoryAccess
import IOKit
@preconcurrency import IOUSBHost
import AccessoryReproCore
import OSLog

private let logSubsystem = "com.qayshp.GuliKitAccessoryRepro"
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
    private var consoleObservers: [NSObjectProtocol] = []
    private let formatter = ISO8601DateFormatter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit AccessoryAccess Repro",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AccessoryAccess Repro — Close Only / No Storage Commands"
        window.delegate = self
        let title = NSTextField(labelWithString: "AccessoryAccess close / reopen")
        title.font = .boldSystemFont(ofSize: 22)
        let scope = NSTextField(wrappingLabelWithString:
            "Validated-device fingerprint: 33fa:ff02, serial 115411. These are not proven model- or unit-unique identifiers.\n"
            + "CLOSE-ONLY VARIANT: no explicit destroy() calls. No firmware, USB configuration, interface, SCSI, reset, or controller-sector I/O.")
        let instructions = NSTextField(wrappingLabelWithString:
            "Use a fresh update-mode session and assign Gulikit to AccessoryAccess Repro in the USB menu. "
            + "Close the normal updater before assigning here. Click each numbered action once. "
            + "A failure stops this session; rear OFF, then Setting + Home creates the next session. "
            + "Quit closes any final client. Keep the Mac unlocked.")
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
        let stack = NSStackView(views: [title, scope, instructions, status, buttons, scroll])
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
                let criteria = AAUSBAccessoryMatchingCriteria(deviceMatchingCriteria: .init(vendorID: 0x33fa, productID: 0xff02))
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
    private func add(_ accessory: AAUSBAccessory) {
        let d = accessory.deviceDescriptorData
        guard d.count == 18, d[0] == 18, d[1] == 1,
              d[8] == 0xfa, d[9] == 0x33, d[10] == 0x02, d[11] == 0xff,
              serial(accessory.registryID) == "115411" else {
            log("Ignored candidate: descriptor or validated serial profile did not match."); return
        }
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
        let idle = !inFlight && !registering && candidates.count == 1
        claimButton.isEnabled = idle && state.canClaim
        closeButton.isEnabled = idle && state.canClose
        reopenButton.isEnabled = idle && state.canReopen && lastClosedDevice == nil
        status.stringValue = "State: \(state.phase.rawValue) · generation \(state.generation) · candidates \(candidates.count)"
            + (state.failure.map { "\nSTOP: \($0) No retry. Use rear OFF, then Setting + Home; reassign a fresh registry session." } ?? "")
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
              let registryID = state.registryID, let accessory = candidates[registryID],
              serial(registryID) == "115411" else { return }
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
                log("\(operation.rawValue) AA open returned trace=\(opened.traceID) physicalRegistryPresent=\(present) returnedRegistryID=\(returnedRegistryID) identityRead=\(identified).")
                guard state.complete(token, physicalRegistryPresent: present && identified,
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
