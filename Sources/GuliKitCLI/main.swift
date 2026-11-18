import Darwin
import Foundation
import NS58Core
import FirmwareDownload
import FirmwareCatalog

@main
enum GuliKitCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "verify":
            guard arguments.count == 2 else {
                throw NS58Error.invalid("usage: gulikit verify /path/to/NS58_Elves2_V3.7.bin")
            }
            let url = try regularFile(arguments[1])
            let firmware = try Data(contentsOf: url)
            try NS58FAT12.verifyFirmware(firmware, filename: url.lastPathComponent)
            print("Firmware: \(url.lastPathComponent)")
            print("Size: \(firmware.count) bytes")
            print("SHA-256: \(NS58FAT12.sha256(firmware))")
            print("Verified NS58 Elves 2 V3.7 firmware")
        case "download":
            guard arguments.count == 3, arguments[1] == "--directory" else {
                throw NS58Error.invalid("usage: gulikit download --directory /existing/output/directory")
            }
            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw NS58Error.invalid("download destination must be an existing directory")
            }
            print("Downloading supported NS58 V\(SupportedFirmware.version) from \(SupportedFirmware.downloadURL.host!)")
            let firmware = try await SupportedFirmware.download()
            let saved = try SupportedFirmware.saveVerified(firmware, in: directory)
            print("Saved: \(saved.path)")
            print("SHA-256: \(NS58FAT12.sha256(firmware))")
            print("Verified package and firmware; no device opened")
        case "plan":
            let options = try parsePlanOptions(Array(arguments.dropFirst()))
            let imageURL = try regularFile(options.image)
            let firmwareURL = try regularFile(options.firmware)
            let baseline = try Data(contentsOf: imageURL)
            let firmware = try Data(contentsOf: firmwareURL)
            let inspection = try NS58FAT12.inspectBaseline(baseline)
            let plan = try NS58FAT12.makeUpdatePlan(
                baseline: baseline,
                firmware: firmware,
                firmwareFilename: firmwareURL.lastPathComponent
            )
            print("Volume: \(inspection.volumeLabel)")
            print("Sector size: \(inspection.bytesPerSector) bytes")
            print("1. Firmware: LBA \(NS58Constants.firmwareStartLBA), \(NS58Constants.firmwareBlocks) blocks, \(plan.firmwarePayload.count) bytes")
            print("   SHA-256: \(NS58FAT12.sha256(plan.firmwarePayload))")
            print("2. FAT and root: LBA \(NS58Constants.metadataStartLBA), \(NS58Constants.metadataBlocks) blocks, \(plan.metadataPayload.count) bytes")
            print("   SHA-256: \(NS58FAT12.sha256(plan.metadataPayload))")
            print("Offline plan prepared; no device opened")
        case "releases":
            try await printReleases(Array(arguments.dropFirst()))
        default:
            throw NS58Error.invalid("unknown command \(command); run gulikit --help")
        }
    }

    private static func regularFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw NS58Error.invalid("input must be a regular file: \(url.path)")
        }
        return url
    }

    private static func parsePlanOptions(_ arguments: [String]) throws -> (image: String, firmware: String) {
        var options: [String: String] = [:]
        guard arguments.count == 4 else {
            throw NS58Error.invalid("usage: gulikit plan --image PATH --firmware PATH")
        }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let name = arguments[index]
            guard ["--image", "--firmware"].contains(name), options[name] == nil else {
                throw NS58Error.invalid("unknown or repeated option: \(name)")
            }
            options[name] = arguments[index + 1]
        }
        guard let image = options["--image"], let firmware = options["--firmware"] else {
            throw NS58Error.invalid("both --image and --firmware are required")
        }
        return (image, firmware)
    }

    private static func printReleases(_ arguments: [String]) async throws {
        var options: Set<String> = []
        for option in arguments {
            guard ["--refresh", "--json"].contains(option), options.insert(option).inserted else {
                throw NS58Error.invalid("unknown or repeated releases option: \(option); usage: gulikit releases [--refresh] [--json]")
            }
        }
        let refresh = options.contains("--refresh")
        // A new in-memory service makes the default deterministic and offline:
        // cachedCheck returns the bundled snapshot, never an HTTP request.
        let service = FirmwareCatalogService(cacheURL: nil)
        var records: [ReleaseRecord] = []
        var refreshFailed = false
        for entry in FirmwareCatalog.entries {
            let check: FirmwareCatalogCheck
            if refresh {
                check = await service.check(entry: entry, force: true, now: Date())
                if check.failure != nil || check.status == .refreshFailed || !check.allowsCurrentComparison {
                    refreshFailed = true
                }
            } else {
                check = await service.cachedCheck(entry: entry, now: Date())
            }
            records.append(ReleaseRecord(entry: entry, check: check))
        }
        if options.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(refresh
                ? "Official release-page advisory; no USB device or firmware payload opened"
                : "Bundled release-page snapshot (offline; not a live latest-version check)")
            let formatter = ISO8601DateFormatter()
            for record in records {
                print("\n\(record.displayName) [\(record.modelCodes.joined(separator: ", "))] — \(record.componentLabel)")
                print("  Version: \(record.version ?? "unknown") · \(record.source) / \(record.status)")
                print("  Official page: \(record.sourceURL.absoluteString)")
                print("  Checked at: \(record.checkedAt.map { formatter.string(from: $0) } ?? "not live-checked")")
                print("  Bundled snapshot reviewed: \(formatter.string(from: record.bundledReviewedAt))")
                if let failure = record.failure { print("  Refresh unavailable: \(failure)") }
                if !record.allowsCurrentComparison { print("  Current/latest comparison unavailable; this value is advisory only.") }
            }
            print("\nAnnounced versions do not authorize an installation or change pinned firmware hashes.")
        }
        // Preserve all records on stdout for CI review, including partial
        // successes, then communicate an incomplete refresh through exit status.
        if refreshFailed {
            throw NS58Error.invalid("one or more official release-page refreshes failed or could not establish a current result; records were still emitted")
        }
    }

    private static func printUsage() {
        print("""
        GuliKit firmware tools and release-page advisories

        gulikit verify /path/to/NS58_Elves2_V3.7.bin
        gulikit download --directory /existing/output/directory
        gulikit plan --image /path/to/baseline.img --firmware /path/to/NS58_Elves2_V3.7.bin
        gulikit releases [--refresh] [--json]

        releases is offline by default; --refresh requests official HTML pages only.
        Announced versions are advisory and do not change install eligibility or hashes.
        USB access and updating are provided by the GuliKitUpdater app.
        """)
    }
}

private struct ReleaseRecord: Encodable {
    let id: String
    let displayName: String
    let modelCodes: [String]
    let componentLabel: String
    let version: String?
    let bundledVersion: String
    let sourceURL: URL
    let checkedAt: Date?
    let bundledReviewedAt: Date
    let status: String
    let source: String
    let failure: String?
    let allowsCurrentComparison: Bool

    init(entry: FirmwareCatalogEntry, check: FirmwareCatalogCheck) {
        id = entry.id
        displayName = entry.displayName
        modelCodes = entry.modelCodes
        componentLabel = entry.componentLabel
        version = check.latestVersion?.rawValue
        bundledVersion = entry.bundledVersion.rawValue
        sourceURL = check.sourceURL
        checkedAt = check.checkedAt
        bundledReviewedAt = entry.bundledReviewedAt
        status = check.status.rawValue
        source = check.source.rawValue
        failure = check.failure
        allowsCurrentComparison = check.allowsCurrentComparison
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, modelCodes, componentLabel, version, bundledVersion
        case sourceURL, checkedAt, bundledReviewedAt, status, source, failure, allowsCurrentComparison
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(modelCodes, forKey: .modelCodes)
        try values.encode(componentLabel, forKey: .componentLabel)
        if let version { try values.encode(version, forKey: .version) }
        else { try values.encodeNil(forKey: .version) }
        try values.encode(bundledVersion, forKey: .bundledVersion)
        try values.encode(sourceURL, forKey: .sourceURL)
        if let checkedAt { try values.encode(checkedAt, forKey: .checkedAt) }
        else { try values.encodeNil(forKey: .checkedAt) }
        try values.encode(bundledReviewedAt, forKey: .bundledReviewedAt)
        try values.encode(status, forKey: .status)
        try values.encode(source, forKey: .source)
        if let failure { try values.encode(failure, forKey: .failure) }
        else { try values.encodeNil(forKey: .failure) }
        try values.encode(allowsCurrentComparison, forKey: .allowsCurrentComparison)
    }
}
