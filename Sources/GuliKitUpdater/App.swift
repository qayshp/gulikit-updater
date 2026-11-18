import AppKit
import AccessoryAccess
import IOKit
@preconcurrency import IOUSBHost
@preconcurrency import USBTransport
import NS58Core
import FirmwareDownload
import OSLog
import Darwin

private let logger = Logger(subsystem: "com.qayshp.GuliKitUpdater", category: "updater")
private let accessoryLogger = Logger(subsystem: "com.qayshp.GuliKitUpdater", category: "accessory-events")

private struct OpenSession: @unchecked Sendable {
    let accessory: AAUSBAccessory
    let device: IOUSBHostDevice
    let transport: GUUSBTransport
    let baseline: Data
    let label: String
    let installedVersion: String?
    let installationBlockReason: String?
    let serial: String
    let attachmentGeneration: UUID
    let deviceTraceID: String
}

private final class Listener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private let eventLock = NSLock()
    private var sequence: UInt64 = 0

    private func deliver(_ accessory: AAUSBAccessory, connected: Bool) {
        // AccessoryAccess invokes listeners on its serial queue. Keep the hop
        // to MainActor FIFO as well; independent unstructured Tasks do not
        // establish an ordering guarantee between connection events.
        eventLock.lock()
        sequence += 1
        let eventSequence = sequence
        let sourceTime = ProcessInfo.processInfo.systemUptime
        let kind = connected ? "connect" : "disconnect"
        accessoryLogger.notice("Callback #\(eventSequence) \(kind, privacy: .public) registry=\(accessory.registryID) sourceUptime=\(sourceTime)")
        DispatchQueue.main.async {
            App.shared.accessoryEvent(accessory, connected: connected,
                sequence: eventSequence, sourceTime: sourceTime)
        }
        eventLock.unlock()
    }
    nonisolated func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        deliver(accessory, connected: true)
    }
    nonisolated func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        deliver(accessory, connected: false)
    }
}

@MainActor
private final class App: NSObject, NSApplicationDelegate {
    static let shared = App()
    private let listener = Listener()
    private var accessories: [UInt64: AAUSBAccessory] = [:]
    private var attachments = NS58AttachmentTracker()
    private var safety = NS58USBSessionSafety()
    private var modelConfirmedRegistryID: UInt64?
    private static let recoveryDefaultsKey = "NS58BlockedUSBInstances-v1"
    private static let recoveryBootKey = "NS58BlockedUSBBoot-v1"
    private let bootSessionID = App.readBootSessionID()
    private static let recoveryInstructions = "Press the rear OFF button, then hold Setting and press Home (the cable may stay connected). Select Use with this Mac and wait for its drive, then attach it to GuliKit Updater. A new USB instance is required; repeated Connect/Reset clicks will not retry this one."
    private var session: OpenSession?
    private var firmwareURL: URL?
    private var inspectionFailure: String?
    private var busy = false
    private var writingRegistryID: UInt64?
    private var writesAcknowledged = false
    private enum USBOperation: String { case inspection, release, installation }
    private var usbOperation: USBOperation?
    private var operationRegistryID: UInt64?
    private var consoleSessionObservers: [NSObjectProtocol] = []
    private var window: NSWindow!
    private var logView = NSTextView()
    private var status = NSTextField(labelWithString: "Connect NS58 (Setting + Home), then attach it to this app from the macOS USB accessory menu.")
    private let controllerStatus = NSTextField(wrappingLabelWithString: "")
    private let firmwareStatus = NSTextField(wrappingLabelWithString: "")
    private let readinessStatus = NSTextField(wrappingLabelWithString: "")
    private let identityStatus = NSTextField(wrappingLabelWithString: "Model is not automatically proven by the updater's USB name or firmware label.")
    private let modelConfirmation = NSButton(checkboxWithTitle: "I checked the controller's physical model label: NS58 / Elves 2 (not NS59 / Elves 2 Pro).", target: nil, action: nil)
    private let copyLogButton = NSButton(title: "Copy Log", target: nil, action: nil)
    private let inspectButton = NSButton(title: "Connect & Inspect", target: nil, action: nil)
    private let resetInspectButton = NSButton(title: "Reset Transport & Inspect…", target: nil, action: nil)
    private let fileButton = NSButton(title: "Choose Firmware…", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download V3.7", target: nil, action: nil)
    private let updateButton = NSButton(title: "Install V3.7", target: nil, action: nil)
    private let releaseButton = NSButton(title: "Release Controller", target: nil, action: nil)
    private let catalogButton = NSButton(title: "Firmware Versions & Official Downloads…", target: nil, action: nil)
    private lazy var catalog = FirmwareCatalogWindowController { [weak self] message in self?.log(message) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        var restored: [UInt64: NS58USBSessionSafety.Reason] = [:]
        for (key, value) in UserDefaults.standard.dictionary(forKey: Self.recoveryDefaultsKey) ?? [:] {
            if let registryID = UInt64(key), let text = value as? String,
               let reason = NS58USBSessionSafety.Reason(rawValue: text) {
                restored[registryID] = reason
            }
        }
        safety = NS58USBSessionSafety(restoring: restored,
            savedBootSessionID: UserDefaults.standard.string(forKey: Self.recoveryBootKey),
            currentBootSessionID: bootSessionID)
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        menu.addItem(appMenu)
        appMenu.submenu = NSMenu()
        appMenu.submenu?.addItem(withTitle: "Quit GuliKit Updater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GuliKit Updater — NS58 Experiment"
        let title = NSTextField(labelWithString: "GuliKit Elves 2 · NS58")
        title.font = .boldSystemFont(ofSize: 22)
        status.maximumNumberOfLines = 3
        let deviceButtons = NSStackView(views: [inspectButton, resetInspectButton, releaseButton])
        let firmwareButtons = NSStackView(views: [downloadButton, fileButton, updateButton, copyLogButton])
        downloadButton.title = "Mirror V3.7 (optional)"
        deviceButtons.spacing = 10; firmwareButtons.spacing = 10
        firmwareStatus.textColor = .secondaryLabelColor
        for (button, action) in [(inspectButton, #selector(inspect)), (fileButton, #selector(chooseFirmware)),
            (resetInspectButton, #selector(resetTransportAndInspect)),
            (modelConfirmation, #selector(confirmPhysicalModel)), (copyLogButton, #selector(copyLog)),
            (downloadButton, #selector(downloadFirmware)), (updateButton, #selector(update)), (releaseButton, #selector(releaseController))] {
            button.target = self; button.action = action
        }
        catalogButton.target = self; catalogButton.action = #selector(showFirmwareCatalog)
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = logView; scroll.hasVerticalScroller = true
        identityStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, controllerStatus, deviceButtons,
            identityStatus, modelConfirmation, catalogButton, firmwareStatus, firmwareButtons, readinessStatus, status, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        for label in [controllerStatus, identityStatus, firmwareStatus, readinessStatus, status] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.minSize = NSSize(width: 860, height: 800)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshButtons()
        catalog.startAutomaticCheck()
        // AccessoryAccess documents logical disconnect/reconnect around
        // console-session transitions. Observe public workspace events without
        // collecting identities or changing lock/sleep settings. These events
        // are not a complete screen-lock detector.
        for name in [NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            consoleSessionObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: nil
            ) { notification in
                logger.notice("Console session event \(notification.name.rawValue, privacy: .public) sourceUptime=\(ProcessInfo.processInfo.systemUptime)")
            })
        }
        log("macOS 27 AccessoryAccess listener starting (33fa:ff02 only).")
        let criteria = AAUSBAccessoryMatchingCriteria(deviceMatchingCriteria: .init(vendorID: 0x33fa, productID: 0xff02))
        Task {
            do {
                let existing = try await AAUSBAccessoryManager.shared.registerListener(listener, matchingCriteria: [criteria])
                log("Listener registered. Matching accessories: \(existing.count).")
                for accessory in existing { connected(accessory) }
            } catch { fail(error) }
        }
        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            Task { try? await Task.sleep(for: .seconds(8)); NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let usbOperation {
            let alert = NSAlert()
            alert.messageText = "USB \(usbOperation.rawValue) is in progress"
            alert.informativeText = "Wait for this USB operation to finish before quitting. Closing an in-flight transfer can leave the controller's protocol state uncertain."
            alert.addButton(withTitle: "Keep Waiting")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        session?.transport.close()
        session?.accessory.close { _ in }
    }
    func log(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        print(text)
        logView.textStorage?.append(NSAttributedString(string: Date().ISO8601Format() + " " + text + "\n"))
        logView.scrollToEndOfDocument(nil)
    }
    private static func readBootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size < 128 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.flatMap { String(validatingCString: $0) }
        }
    }
    @objc func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logView.string, forType: .string)
    }
    @objc private func showFirmwareCatalog() { catalog.present() }
    @objc func confirmPhysicalModel() {
        guard !busy, let opened = session,
              safety.reason(for: opened.accessory.registryID) == nil else { return }
        modelConfirmedRegistryID = modelConfirmation.state == .on ? opened.accessory.registryID : nil
        log(modelConfirmedRegistryID == nil ? "Physical model confirmation cleared."
            : "User confirmed the physical label says NS58 / Elves 2. This is not USB auto-detection.")
        refreshButtons()
    }
    private func requireFreshSession(_ registryID: UInt64, reason: NS58USBSessionSafety.Reason) {
        safety.requireFreshSession(registryID, reason: reason)
        let saved = Dictionary(uniqueKeysWithValues: safety.blockedSessions.map { (String($0.key), $0.value.rawValue) })
        if let bootSessionID {
            UserDefaults.standard.set(saved, forKey: Self.recoveryDefaultsKey)
            UserDefaults.standard.set(bootSessionID, forKey: Self.recoveryBootKey)
        } else {
            log("Boot namespace unavailable; recovery gate is active in this app instance but cannot be restored across relaunch.")
        }
        if modelConfirmedRegistryID == registryID { modelConfirmedRegistryID = nil }
        let effectiveReason = safety.reason(for: registryID) ?? reason
        let guidance = usbOperation == .installation
            ? "Installation is still in progress: keep the controller connected and wait for completion. No retry is permitted."
            : Self.recoveryInstructions
        log("USB instance \(registryID) is consumed/blocked: \(effectiveReason.explanation) \(guidance)")
    }
    private func failUSB(_ error: Error, registryID: UInt64, reason: NS58USBSessionSafety.Reason) {
        requireFreshSession(registryID, reason: reason)
        inspectionFailure = (error as? NS58Error)?.description ?? error.localizedDescription
        fail(error)
    }
    func fail(_ error: Error) {
        let message = (error as? NS58Error)?.description ?? error.localizedDescription
        usbOperation = nil; operationRegistryID = nil; busy = false; status.stringValue = "Operation failed: \(message)"
        log("ERROR: \(error)"); refreshButtons()
    }
    func refreshButtons() {
        let candidate = accessories.count == 1 ? accessories.values.first : nil
        let recoveryReason = candidate.flatMap { safety.reason(for: $0.registryID) }
        inspectButton.isEnabled = candidate.map {
            safety.canInspect(registryID: $0.registryID, busy: busy, hasClaim: session != nil,
                candidateCount: accessories.count, previouslyWrote: writingRegistryID == $0.registryID)
        } ?? false
        resetInspectButton.isEnabled = inspectButton.isEnabled
        fileButton.isEnabled = !busy
        downloadButton.isEnabled = !busy
        updateButton.isEnabled = session.map {
            safety.canInstall(registryID: $0.accessory.registryID, busy: busy, hasClaim: true,
                hasFirmware: firmwareURL != nil, modelConfirmed: modelConfirmedRegistryID == $0.accessory.registryID,
                baselineValidated: $0.installationBlockReason == nil,
                previouslyWrote: writingRegistryID == $0.accessory.registryID, candidateCount: accessories.count)
        } ?? false
        releaseButton.isEnabled = !busy && session != nil
        modelConfirmation.isEnabled = !busy && session != nil && recoveryReason == nil
        modelConfirmation.state = session != nil && modelConfirmedRegistryID == session?.accessory.registryID ? .on : .off
        if let opened = session {
            controllerStatus.stringValue = "NS58 transport/read profile matched · \(opened.label) · read-only inspection passed · exclusive USB access"
            identityStatus.stringValue = "USB 33fa:ff02 · serial \(opened.serial) · captured test-unit/profile match. These identifiers are not proven exclusive to NS58; verify the physical model label."
        } else if let recoveryReason {
            controllerStatus.stringValue = "USB session needs a fresh start: \(recoveryReason.explanation)"
        } else if let inspectionFailure {
            controllerStatus.stringValue = "Controller inspection failed: \(inspectionFailure)"
        } else {
            controllerStatus.stringValue = "Controller: \(accessories.count) GuliKit updater candidate(s). USB matching alone does not identify the model."
        }
        if session == nil { identityStatus.stringValue = "NS58-only experiment. USB/FAT profile checks and firmware hash are required, but do not independently prove the controller model." }
        if let firmwareURL {
            firmwareStatus.stringValue = "Firmware selected and verified: \(firmwareURL.lastPathComponent)\n\(firmwareURL.path)"
        } else {
            firmwareStatus.stringValue = "Firmware: none selected. Open the official page in Firmware Versions, download/extract in your browser, then choose the verified V3.7 BIN. The mirror is optional and third-party."
        }
        if busy {
            readinessStatus.stringValue = "Operation in progress. Installation controls are locked."
        } else if let recoveryReason {
            readinessStatus.stringValue = "\(recoveryReason.explanation) \(Self.recoveryInstructions)"
        } else if let writingRegistryID, accessories[writingRegistryID] != nil {
            readinessStatus.stringValue = "Install unavailable: this USB session already attempted an update. Power off and re-enter update mode."
        } else if session == nil {
            readinessStatus.stringValue = "Install unavailable: Connect & Inspect has not succeeded. Downloading firmware does not inspect or write the controller."
        } else if let reason = session?.installationBlockReason {
            readinessStatus.stringValue = "The volume label was read, but installation is not validated for this baseline: \(reason) No write or automatic retry is permitted."
        } else if modelConfirmedRegistryID != session?.accessory.registryID {
            readinessStatus.stringValue = "Install unavailable: check the physical NS58 model label and tick its confirmation. USB identity and GuliKit 3.7 alone are not a model guarantee."
        } else if firmwareURL == nil {
            readinessStatus.stringValue = "Controller ready. Download V3.7 or choose the supported BIN to enable Install."
        } else {
            readinessStatus.stringValue = "Ready for a V3.7 reinstall. Install opens a confirmation before any firmware write."
        }
        catalog.setNS58Observation(version: session?.installedVersion, label: session?.label,
            physicalModelConfirmed: session != nil && modelConfirmedRegistryID == session?.accessory.registryID)
    }
    func accessoryEvent(_ accessory: AAUSBAccessory, connected: Bool,
        sequence: UInt64, sourceTime: TimeInterval) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
            IORegistryEntryIDMatching(accessory.registryID))
        let physicallyPresent = service != IO_OBJECT_NULL
        if physicallyPresent { IOObjectRelease(service) }
        let delay = (ProcessInfo.processInfo.systemUptime - sourceTime) * 1000
        log("Accessory event #\(sequence) \(connected ? "connect" : "disconnect") "
            + "deliveryDelayMs=\(String(format: "%.1f", delay)) "
            + "phase=\(usbOperation?.rawValue ?? "idle") physicalRegistryPresent=\(physicallyPresent)")
        if connected { self.connected(accessory) } else { disconnected(accessory) }
    }
    func connected(_ accessory: AAUSBAccessory) {
        do { _ = try NS58UpdaterDescriptor(validating: accessory.deviceDescriptorData) }
        catch {
            accessories.removeValue(forKey: accessory.registryID)
            attachments.detach(registryID: accessory.registryID)
            modelConfirmedRegistryID = nil
            log("Updater descriptor rejected: \(error)"); refreshButtons(); return
        }
        let newAttachment = attachments.generation(for: accessory.registryID) == nil
        accessories[accessory.registryID] = accessory
        attachments.attach(registryID: accessory.registryID)
        if newAttachment {
            modelConfirmedRegistryID = nil
            if safety.reason(for: accessory.registryID) == nil, !busy, session == nil {
                inspectionFailure = nil
            }
        }
        if !busy && session == nil && inspectionFailure == nil {
            status.stringValue = "Found \(accessories.count) GuliKit updater candidate(s)."
        }
        log("GuliKit updater profile candidate attached, registry \(accessory.registryID).")
        if let reason = safety.reason(for: accessory.registryID) {
            log("Same USB instance remains blocked after attachment: \(reason.explanation)")
        }
        refreshButtons()
    }
    func disconnected(_ accessory: AAUSBAccessory) {
        if (usbOperation == .inspection && operationRegistryID == accessory.registryID)
            || session?.accessory.registryID == accessory.registryID {
            requireFreshSession(accessory.registryID, reason: .ownershipLost)
        }
        if modelConfirmedRegistryID == accessory.registryID { modelConfirmedRegistryID = nil }
        accessories.removeValue(forKey: accessory.registryID)
        attachments.detach(registryID: accessory.registryID)
        if writingRegistryID == accessory.registryID {
            // This notification may also mean the person detached the accessory
            // from this app. The worker checks physical registry disappearance.
            log("Accessory detached from app during update; checking physical USB state.")
        } else if session?.accessory.registryID == accessory.registryID {
            // Established sessions have no USB worker outside the update branch.
            session?.transport.close(); session = nil
            status.stringValue = "Controller disconnected."
        }
        log("USB accessory disconnected, registry \(accessory.registryID).")
        refreshButtons()
    }
    @objc func inspect() {
        beginInspection(resetTransport: false)
    }
    @objc func resetTransportAndInspect() {
        guard !busy, session == nil, accessories.count == 1,
              let accessory = accessories.values.first,
              let generation = attachments.generation(for: accessory.registryID),
              safety.reason(for: accessory.registryID) == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Reset the NS58 mass-storage transport once?"
        alert.informativeText = "Sends one USB mass-storage class reset, clears the IN and OUT endpoint halts, then inspects the controller. No firmware or disk writes are sent. This is not a USB device/port reset. Stops on any failure; no automatic retry."
        alert.addButton(withTitle: "Reset Once & Inspect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !busy, session == nil, accessories.count == 1,
              accessories.values.first?.registryID == accessory.registryID,
              attachments.isCurrent(registryID: accessory.registryID, generation: generation),
              safety.reason(for: accessory.registryID) == nil else {
            log("Transport reset cancelled: the confirmed attachment changed. No reset sent.")
            return
        }
        beginInspection(resetTransport: true)
    }
    private func beginInspection(resetTransport: Bool) {
        guard !busy, session == nil, accessories.count == 1, let accessory = accessories.values.first,
              let generation = attachments.generation(for: accessory.registryID) else { return }
        guard safety.canInspect(registryID: accessory.registryID, busy: busy, hasClaim: session != nil,
            candidateCount: accessories.count, previouslyWrote: writingRegistryID == accessory.registryID) else { return }
        inspectionFailure = nil
        usbOperation = .inspection
        operationRegistryID = accessory.registryID
        busy = true; refreshButtons(); log("Requesting exclusive USB access; approve the macOS prompt.")
        if resetTransport { log("Explicit one-shot BOT transport initialization requested; no firmware writes.") }
        Task {
            do {
                let device = try await accessory.open(serviceQueue: nil)
                let deviceTraceID = GUUSBTransport.traceDeviceLifetime(device)
                let mode = resetTransport ? "explicit transport initialization and inspection" : "read-only inspection"
                log("Exclusive USB claim granted, device trace \(deviceTraceID). Opening the NS58 mass-storage interface for \(mode).")
                do {
                    guard attachments.isCurrent(registryID: accessory.registryID, generation: generation) else {
                        throw NS58Error.invalid("Accessory ownership changed while requesting access; no inspection commands sent")
                    }
                    let opened = try await Task.detached { () throws -> OpenSession in
                        let serialRef = IORegistryEntryCreateCFProperty(device.ioService, "USB Serial Number" as CFString,
                            kCFAllocatorDefault, 0)?.takeRetainedValue()
                        guard let serial = serialRef as? String, serial == NS58UpdaterDescriptor.validatedSerial else {
                            throw NS58Error.invalid("USB serial does not match the validated test-unit profile; this is not automatic model detection")
                        }
                        let transport: GUUSBTransport
                        do { transport = try GUUSBTransport(device: device) }
                        catch { throw NS58Error.invalid("Opening the USB mass-storage interface failed: \(error)") }
                        do {
                            if resetTransport { try transport.resetBulkOnlyTransport() }
                            let capacity = try transport.readCapacity()
                            guard capacity == Data([0,0,0,118,0,0,16,0]) else {
                                throw NS58Error.invalid("Unexpected NS58 SCSI capacity")
                            }
                            let baseline = try transport.readBlocks(atLBA: 0, count: 23)
                            let observation = try NS58VersionProbe.inspect(baseline)
                            let installationBlockReason: String?
                            do {
                                _ = try NS58FAT12.inspectBaseline(baseline)
                                installationBlockReason = nil
                            } catch {
                                // Successfully reading an older/unrecognized
                                // label is not a USB transport failure. Keep
                                // the existing writer strictly unavailable.
                                installationBlockReason = String(describing: error)
                            }
                            return OpenSession(accessory: accessory, device: device, transport: transport,
                                baseline: baseline, label: observation.volumeLabel, installedVersion: observation.version,
                                installationBlockReason: installationBlockReason, serial: serial,
                                attachmentGeneration: generation, deviceTraceID: deviceTraceID)
                        } catch { transport.close(); throw error }
                    }.value
                    guard attachments.isCurrent(registryID: accessory.registryID, generation: generation) else {
                        opened.transport.close()
                        throw NS58Error.invalid("Accessory ownership changed during inspection; stale result discarded")
                    }
                    session = opened
                    writingRegistryID = nil
                    status.stringValue = opened.installedVersion == nil
                        ? "Volume label read · \(opened.label). Installed version is unknown; Install remains disabled."
                        : "Read-only version inspection passed · \(opened.label). Installation eligibility is checked separately."
                    log("USB CLAIM + BOT READ PASS: 119 × 4096 bytes; FAT label \(opened.label); strict installation baseline=\(opened.installationBlockReason == nil).")
                    if let reason = opened.installationBlockReason {
                        log("Read-only observation retained; Install remains disabled: \(reason). This is not classified as a transport failure.")
                    }
                    usbOperation = nil; operationRegistryID = nil; busy = false; refreshButtons()
                } catch {
                    do {
                        try await accessory.close()
                        log("Inspection failure cleanup: accessory close returned.")
                    } catch {
                        log("Inspection failure cleanup: accessory close failed: \(error)")
                    }
                    throw error
                }
            } catch {
                failUSB(error, registryID: accessory.registryID, reason: .inspectionFailed)
            }
        }
    }
    @objc func chooseFirmware() {
        guard !busy else { return }
        busy = true; refreshButtons()
        defer { busy = false; refreshButtons() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Select the extracted official NS58_Elves2_V3.7.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try NS58FAT12.verifyFirmware(Data(contentsOf: url), filename: url.lastPathComponent)
            firmwareURL = url; log("Firmware verified: \(url.lastPathComponent), SHA-256 matches known V3.7.")
            refreshButtons()
        } catch { fail(error) }
    }
    @objc func downloadFirmware() {
        guard !busy else { return }
        busy = true; refreshButtons()
        status.stringValue = "Downloading and verifying supported NS58 firmware V3.7…"
        log("Downloading supported V3.7 from TousLesDrivers. Package and BIN hashes are pinned.")
        Task {
            do {
                let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                let directory = caches.appendingPathComponent("NS58-V3.7", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let cached = directory.appendingPathComponent(NS58Constants.firmwareName)
                if FileManager.default.fileExists(atPath: cached.path) {
                    try NS58FAT12.verifyFirmware(Data(contentsOf: cached), filename: cached.lastPathComponent)
                    firmwareURL = cached
                } else {
                    let firmware = try await SupportedFirmware.download()
                    firmwareURL = try SupportedFirmware.saveVerified(firmware, in: directory)
                }
                log("Supported V3.7 BIN verified and selected. Inspect the controller and confirm its physical NS58 label before Install.")
                status.stringValue = "NS58 V3.7 downloaded and verified."
                busy = false; refreshButtons()
            } catch { fail(error) }
        }
    }
    @objc func releaseController() {
        guard let opened = session, !busy else { return }
        // Reclaim after close is experimentally unreliable. Keep that cycle in
        // the separate non-flashing repro, not in the ordinary install workflow.
        requireFreshSession(opened.accessory.registryID, reason: .released)
        // Invalidate readiness before closing. A failed accessory release must
        // never leave Install enabled on a transport that is already closed.
        session = nil; usbOperation = .release; operationRegistryID = opened.accessory.registryID
        busy = true; refreshButtons()
        log("USB release begin, device trace \(opened.deviceTraceID).")
        opened.transport.close()
        Task {
            do {
                try await opened.accessory.close()
                log("Accessory close returned; completing device-client teardown, trace \(opened.deviceTraceID).")
                // AA close invalidates the old device. Explicit destroy is
                // documented as idempotent; complete it before allowing another
                // claim rather than relying on later ARC/framework cleanup.
                // Never perform this blocking call in a completion handler.
                await Task.detached { opened.device.destroy() }.value
                log("Device-client teardown returned, trace \(opened.deviceTraceID).")
                usbOperation = nil; operationRegistryID = nil; busy = false; status.stringValue = "Controller released. Start a fresh update-mode session before reconnecting."
                log(status.stringValue); refreshButtons()
            } catch {
                failUSB(error, registryID: opened.accessory.registryID, reason: .releaseFailed)
            }
        }
    }
    @objc func update() {
        guard let opened = session, let url = firmwareURL,
              safety.canInstall(registryID: opened.accessory.registryID, busy: busy, hasClaim: true,
                hasFirmware: true, modelConfirmed: modelConfirmedRegistryID == opened.accessory.registryID,
                baselineValidated: opened.installationBlockReason == nil,
                previouslyWrote: writingRegistryID == opened.accessory.registryID,
                candidateCount: accessories.count) else { return }
        let alert = NSAlert()
        alert.messageText = "Install NS58 firmware V3.7?"
        alert.informativeText = "You confirmed the physical label says NS58 / Elves 2, not NS59 / Elves 2 Pro. USB profile matching alone does not prove the model. This writes firmware once. Keep it connected until the controller powers itself off. The installed version is already 3.7."
        alert.addButton(withTitle: "Install Once"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard session?.accessory.registryID == opened.accessory.registryID,
              safety.canInstall(registryID: opened.accessory.registryID, busy: busy, hasClaim: true,
                hasFirmware: firmwareURL == url, modelConfirmed: modelConfirmedRegistryID == opened.accessory.registryID,
                baselineValidated: opened.installationBlockReason == nil,
                previouslyWrote: writingRegistryID == opened.accessory.registryID,
                candidateCount: accessories.count),
              attachments.isCurrent(registryID: opened.accessory.registryID,
                  generation: opened.attachmentGeneration) else {
            log("Install cancelled because the inspected accessory was detached.")
            return
        }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let firmware = try Data(contentsOf: url)
            try NS58FAT12.verifyFirmware(firmware, filename: url.lastPathComponent)
            busy = true; usbOperation = .installation; writingRegistryID = opened.accessory.registryID
            operationRegistryID = opened.accessory.registryID
            requireFreshSession(opened.accessory.registryID, reason: .updateAttempted)
            writesAcknowledged = false; refreshButtons()
            log("LIVE WRITE START: LBA 10 (53248 bytes), then LBA 1 (12288 bytes).")
            Task {
                do {
                    try await Task.detached {
                        // Re-read under the same exclusive claim immediately before writing.
                        let baseline = try opened.transport.readBlocks(atLBA: 0, count: 23)
                        let plan = try NS58FAT12.makeUpdatePlan(baseline: baseline,
                            firmware: firmware, firmwareFilename: url.lastPathComponent)
                        try opened.transport.writeBlocks(atLBA: 10, data: plan.firmwarePayload)
                        try opened.transport.writeBlocks(atLBA: 1, data: plan.metadataPayload)
                    }.value
                    writesAcknowledged = true
                    log("Both BOT writes acknowledged. Waiting up to 60 seconds for physical USB disconnect.")
                    var disappeared = false
                    for _ in 0..<120 {
                        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                            IORegistryEntryIDMatching(opened.accessory.registryID))
                        if service == IO_OBJECT_NULL { disappeared = true; break }
                        IOObjectRelease(service)
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    status.stringValue = disappeared
                        ? "Both writes acknowledged; USB device disappeared. Confirm automatic power-off, then restart and inspect."
                        : "Writes acknowledged; no physical USB disconnect in 60 seconds. Update unconfirmed."
                    log(status.stringValue)
                    opened.transport.close()
                    try? await opened.accessory.close()
                    session = nil; usbOperation = nil; operationRegistryID = nil; busy = false; refreshButtons()
                } catch {
                    // Close only after the transfer worker returned; never race a pipe request.
                    opened.transport.close()
                    try? await opened.accessory.close()
                    session = nil
                    fail(NS58Error.invalid("Transfer failed; update unconfirmed: \(error). Reconnect before another attempt."))
                }
            }
        } catch { fail(error) }
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.delegate = App.shared
        app.run()
    }
}
