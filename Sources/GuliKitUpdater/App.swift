import AppKit
import AccessoryAccess
import IOKit
@preconcurrency import IOUSBHost
@preconcurrency import USBTransport
import NS58Core
import FirmwareDownload
import OSLog

private let logger = Logger(subsystem: "com.qayshp.GuliKitUpdater", category: "updater")

private struct OpenSession: @unchecked Sendable {
    let accessory: AAUSBAccessory
    let device: IOUSBHostDevice
    let transport: GUUSBTransport
    let baseline: Data
    let label: String
    let serial: String
}

private final class Listener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    nonisolated func usbAccessoryDidConnect(_ accessory: AAUSBAccessory) {
        Task { @MainActor in App.shared.connected(accessory) }
    }
    nonisolated func usbAccessoryDidDisconnect(_ accessory: AAUSBAccessory) {
        Task { @MainActor in App.shared.disconnected(accessory) }
    }
}

@MainActor
private final class App: NSObject, NSApplicationDelegate {
    static let shared = App()
    private let listener = Listener()
    private var accessories: [UInt64: AAUSBAccessory] = [:]
    private var session: OpenSession?
    private var firmwareURL: URL?
    private var busy = false
    private var writingRegistryID: UInt64?
    private var writesAcknowledged = false
    private var window: NSWindow!
    private var logView = NSTextView()
    private var status = NSTextField(labelWithString: "Connect NS58 (Setting + Home), then attach it to this app from the macOS USB accessory menu.")
    private let inspectButton = NSButton(title: "Connect & Inspect", target: nil, action: nil)
    private let fileButton = NSButton(title: "Choose Firmware…", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download V3.7", target: nil, action: nil)
    private let updateButton = NSButton(title: "Install V3.7", target: nil, action: nil)
    private let releaseButton = NSButton(title: "Release Controller", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        menu.addItem(appMenu)
        appMenu.submenu = NSMenu()
        appMenu.submenu?.addItem(withTitle: "Quit GuliKit Updater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GuliKit Updater — NS58 Experiment"
        let title = NSTextField(labelWithString: "GuliKit Elves 2 · NS58")
        title.font = .boldSystemFont(ofSize: 22)
        status.maximumNumberOfLines = 3
        let buttons = NSStackView(views: [inspectButton, fileButton, downloadButton, updateButton, releaseButton])
        buttons.spacing = 10
        for (button, action) in [(inspectButton, #selector(inspect)), (fileButton, #selector(chooseFirmware)),
            (downloadButton, #selector(downloadFirmware)), (updateButton, #selector(update)), (releaseButton, #selector(releaseController))] {
            button.target = self; button.action = action
        }
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = logView; scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [title, status, buttons, scroll])
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
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshButtons()
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
        if busy && writingRegistryID != nil {
            let alert = NSAlert()
            alert.messageText = "An update is in progress"
            alert.informativeText = "Wait for the controller to finish and power itself off before quitting."
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
        logView.textStorage?.append(NSAttributedString(string: text + "\n"))
        logView.scrollToEndOfDocument(nil)
    }
    func fail(_ error: Error) {
        busy = false; status.stringValue = "Operation failed: \(error.localizedDescription)"
        log("ERROR: \(error)"); refreshButtons()
    }
    func refreshButtons() {
        inspectButton.isEnabled = !busy && session == nil && accessories.count == 1
        fileButton.isEnabled = !busy
        downloadButton.isEnabled = !busy
        updateButton.isEnabled = !busy && session != nil && firmwareURL != nil && writingRegistryID == nil
        releaseButton.isEnabled = !busy && session != nil
    }
    func connected(_ accessory: AAUSBAccessory) {
        let d = accessory.deviceDescriptorData
        guard d.count >= 18, d[8] == 0xfa, d[9] == 0x33, d[10] == 0x02, d[11] == 0xff else { return }
        accessories[accessory.registryID] = accessory
        status.stringValue = "Found \(accessories.count) NS58 updater candidate(s)."
        log("NS58 updater attached, registry \(accessory.registryID).")
        refreshButtons()
    }
    func disconnected(_ accessory: AAUSBAccessory) {
        accessories.removeValue(forKey: accessory.registryID)
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
        guard !busy, accessories.count == 1, let accessory = accessories.values.first else { return }
        guard writingRegistryID != accessory.registryID else {
            fail(NS58Error.invalid("This USB session already attempted an update. Power off and re-enter update mode."))
            return
        }
        busy = true; refreshButtons(); log("Requesting exclusive USB access; approve the macOS prompt.")
        Task {
            do {
                let device = try await accessory.open(serviceQueue: nil)
                do {
                    let opened = try await Task.detached { () throws -> OpenSession in
                        let serialRef = IORegistryEntryCreateCFProperty(device.ioService, "USB Serial Number" as CFString,
                            kCFAllocatorDefault, 0)?.takeRetainedValue()
                        guard let serial = serialRef as? String, serial == "115411" else {
                            throw NS58Error.invalid("USB serial does not match the validated NS58 unit")
                        }
                        let transport = try GUUSBTransport(device: device)
                        do {
                            let capacity = try transport.readCapacity()
                            guard capacity == Data([0,0,0,118,0,0,16,0]) else {
                                throw NS58Error.invalid("Unexpected NS58 SCSI capacity")
                            }
                            let baseline = try transport.readBlocks(atLBA: 0, count: 23)
                            let inspection = try NS58FAT12.inspectBaseline(baseline)
                            return OpenSession(accessory: accessory, device: device, transport: transport,
                                baseline: baseline, label: inspection.volumeLabel, serial: serial)
                        } catch { transport.close(); throw error }
                    }.value
                    guard accessories[accessory.registryID] != nil else {
                        opened.transport.close()
                        throw NS58Error.invalid("Accessory was detached during inspection")
                    }
                    session = opened
                    writingRegistryID = nil
                    status.stringValue = "NS58 · \(opened.label) · USB claimed · ready for V3.7 reinstall"
                    log("USB CLAIM + BOT READ PASS: 119 × 4096 bytes; FAT label \(opened.label).")
                    busy = false; refreshButtons()
                } catch {
                    try? await accessory.close()
                    throw error
                }
            } catch { fail(error) }
        }
    }
    @objc func chooseFirmware() {
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
                log("Supported V3.7 BIN verified and selected. Click Install V3.7 after inspecting the controller.")
                status.stringValue = "NS58 V3.7 downloaded and verified."
                busy = false; refreshButtons()
            } catch { fail(error) }
        }
    }
    @objc func releaseController() {
        guard let opened = session, !busy else { return }
        busy = true; refreshButtons()
        opened.transport.close()
        Task {
            do {
                try await opened.accessory.close()
                session = nil; busy = false; status.stringValue = "Controller released to macOS."
                log(status.stringValue); refreshButtons()
            } catch { fail(error) }
        }
    }
    @objc func update() {
        guard let opened = session, let url = firmwareURL, !busy, writingRegistryID == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Install NS58 firmware V3.7?"
        alert.informativeText = "This writes firmware once to the connected NS58. Keep it connected until the controller powers itself off. The installed version is already 3.7."
        alert.addButton(withTitle: "Install Once"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !busy, session?.accessory.registryID == opened.accessory.registryID,
              accessories[opened.accessory.registryID] != nil else {
            log("Install cancelled because the inspected accessory was detached.")
            return
        }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let firmware = try Data(contentsOf: url)
            try NS58FAT12.verifyFirmware(firmware, filename: url.lastPathComponent)
            busy = true; writingRegistryID = opened.accessory.registryID
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
                    session = nil; busy = false; refreshButtons()
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
