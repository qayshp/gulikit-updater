import AppKit
import FirmwareCatalog

/// Advisory-only browser of official release announcements. It has no USB,
/// firmware-download, or installation dependency and cannot enable Install.
@MainActor
final class FirmwareCatalogWindowController: NSWindowController {
    private let service: FirmwareCatalogService
    private let report: @MainActor (String) -> Void
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 690, height: 300))
    private let checkButton = NSButton(title: "Check All Models Now", target: nil, action: nil)
    private let officialButton = NSButton(title: "Open Official Firmware Page", target: nil, action: nil)
    private let progress = NSTextField(wrappingLabelWithString: "")
    private var results: [String: FirmwareCatalogCheck] = [:]
    private var checking = false
    private var started = false
    private var installedVersion: String?
    private var installedLabel: String?
    private var physicalModelConfirmed = false
    private var freshnessTimer: Timer?

    init(report: @escaping @MainActor (String) -> Void) {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FirmwareCatalog", isDirectory: true)
            .appendingPathComponent("official-release-observations.json")
        service = FirmwareCatalogService(cacheURL: cache)
        self.report = report
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func createWindow() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Firmware Versions & Official Downloads"
        panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Official firmware announcements")
        title.font = .boldSystemFont(ofSize: 21)
        let scope = NSTextField(wrappingLabelWithString:
            "Catalog entries distinguish main firmware, Bluetooth firmware, and combined packages. This app still installs only the verified NS58 V3.7 firmware.\n"
            + "Checks read public GuliKit pages only. Download in your browser and complete any CAPTCHA there; no firmware is downloaded by this checker.")
        for entry in FirmwareCatalog.entries { modelPicker.addItem(withTitle: "\(entry.displayName) · \(entry.componentLabel)") }
        modelPicker.target = self; modelPicker.action = #selector(selectionChanged)
        checkButton.target = self; checkButton.action = #selector(checkNow)
        officialButton.target = self; officialButton.action = #selector(openOfficialPage)
        details.isEditable = false; details.isSelectable = true
        details.font = .systemFont(ofSize: 13)
        details.isVerticallyResizable = true; details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        details.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.documentView = details; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        progress.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [checkButton, officialButton]); actions.spacing = 12
        let stack = NSStackView(views: [title, scope, modelPicker, scroll, actions, progress])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        for label in [scope, progress] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        panel.minSize = NSSize(width: 720, height: 590)
        panel.center(); window = panel
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                self.refresh() // Expire advice even if the window is left open.
            }
        }
        refresh()
    }

    func present() {
        // init(window: nil) has no nib to load, so showWindow does not
        // construct this programmatic window. Reuse it after closing.
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        refreshAll(force: false) // Cache/backoff applies when reopened days later.
    }

    func setNS58Observation(version: String?, label: String?, physicalModelConfirmed: Bool) {
        installedVersion = version; installedLabel = label
        self.physicalModelConfirmed = physicalModelConfirmed
        if window != nil { refresh() }
    }

    func startAutomaticCheck() {
        guard !started else { return }
        started = true
        refreshAll(force: false)
    }

    @objc private func selectionChanged() { refresh() }
    @objc private func checkNow() { refreshAll(force: true) }
    private var selection: FirmwareCatalogEntry? {
        let index = modelPicker.indexOfSelectedItem
        return FirmwareCatalog.entries.indices.contains(index) ? FirmwareCatalog.entries[index] : nil
    }

    @objc private func openOfficialPage() {
        guard let entry = selection else { return }
        let page = officialPage(for: entry)
        if NSWorkspace.shared.open(page) {
            report("Opened official firmware page for \(entry.id): \(page.absoluteString). Browser handles package download/CAPTCHA; no controller operation.")
        } else { report("Could not open official firmware page for \(entry.id).") }
    }

    private func officialPage(for entry: FirmwareCatalogEntry) -> URL {
        // Keep navigation within official article URLs, never the file link
        // from inside an article or a source supplied by arbitrary input.
        if let page = results[entry.id]?.sourceURL, FirmwareCatalogService.isOfficialArticleURL(page) {
            return page
        }
        return entry.officialPage
    }

    private func refreshAll(force: Bool) {
        guard !checking else { return }
        checking = true
        if window != nil { refresh() }
        report("Official release metadata check START; \(FirmwareCatalog.entries.count) model/component records. No payload download or USB operation.")
        Task {
            // Sequential and bounded; entries sharing a page are coalesced by
            // the service. Do not flood the site with parallel launch requests.
            for entry in FirmwareCatalog.entries {
                results[entry.id] = await service.cachedCheck(entry: entry, now: Date())
            }
            if window != nil { refresh() }
            var failures = 0
            var limited = 0
            for entry in FirmwareCatalog.entries {
                let result = await service.check(entry: entry, force: force, now: Date())
                results[entry.id] = result
                if result.failure != nil { failures += 1 }
                if result.discoveryWarning != nil { limited += 1 }
                report("Release metadata \(entry.id): \(result.status), version=\(result.latestVersion?.rawValue ?? "unknown"), source=\(result.source).")
                if window != nil { refresh() }
            }
            checking = false
            report("Official release metadata check END; unavailable/failed records=\(failures), limited listing coverage=\(limited). Installation policy unchanged.")
            if window != nil { refresh() }
        }
    }

    private func refresh() {
        checkButton.isEnabled = !checking
        progress.stringValue = checking ? "Checking official announcements… No device access."
            : "Automatic refresh uses a 24-hour successful-check cache and failure backoff. A failed or stale check never means ‘up to date’."
        guard let entry = selection else { return }
        let current = results[entry.id]
        let now = Date()
        let observationStatus = current.map { result in
            if result.status == .fresh, result.discoveryWarning != nil { return "limited coverage" }
            return result.status == .fresh && !result.isCurrent(at: now) ? "stale" : result.status.rawValue
        } ?? "bundled"
        let latest = current?.latestVersion?.rawValue ?? entry.bundledVersion.rawValue
        let checked = current?.checkedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No successful live check"
        let reviewed = entry.bundledReviewedAt.formatted(date: .abbreviated, time: .omitted)
        let model = entry.modelCodes == [entry.displayName] ? entry.displayName
            : "\(entry.displayName) · \(entry.modelCodes.joined(separator: ", "))"
        var lines = ["\(model) · \(entry.componentLabel)",
            "\(entry.component == .package ? "Latest observed package release" : "Latest observed/listed"): \(latest)",
            "Information source: \(current.map { String(describing: $0.source) } ?? "bundled") · \(observationStatus)",
            "Last successful website check: \(checked)", "Bundled snapshot reviewed: \(reviewed)"]
        if entry.component == .package {
            lines.append("GuliKit lists this as one package release. It is not a separate installed version for either chip.")
        } else if entry.component == .bluetooth {
            lines.append("This official listing covers Bluetooth only; it does not identify the main firmware version.")
        }
        if entry.id == "ns58-main", let installedVersion {
            lines.append("Installed label: \(installedLabel ?? installedVersion)")
            if physicalModelConfirmed, let current {
                switch current.advice(installed: installedVersion, now: now) {
                case .newerAvailable: lines.append("Status: Newer main firmware is listed for this model.")
                case .upToDate: lines.append("Status: Matches the newest main firmware found in the checked GuliKit listings.")
                case .installedNewer: lines.append("Status: Installed version is newer than the listed release; no downgrade suggested.")
                case .unknown: lines.append("Status: Cannot make a current comparison. Check the official page; cached data may be stale.")
                }
            } else { lines.append("Status: Confirm the physical NS58 model label in the main window before comparing; USB identity alone is not model proof.") }
        } else if entry.id == "ns58-main", let installedLabel {
            lines.append("Observed volume label: \(installedLabel)")
            lines.append("Installed version: unknown; the readable label is not a recognized numeric firmware version. No version comparison made.")
        } else {
            lines.append("Installed version: unknown. Selecting a catalog model does not identify or claim a USB device.")
        }
        if let failure = current?.failure { lines.append("Could not refresh: \(failure)") }
        if let warning = current?.discoveryWarning { lines.append("Listing coverage: \(warning)") }
        lines.append("Official page: \(officialPage(for: entry).absoluteString)")
        lines.append(entry.id == "ns58-main"
            ? "Install support: verified V3.7 only, and only when the original strict write-baseline and physical-model checks pass."
            : "Install support: not validated in this app. Official information and links only.")
        details.string = lines.joined(separator: "\n\n")
    }
}
