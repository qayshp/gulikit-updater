import Foundation

/// Numeric firmware components, scoped by the caller to one model/component.
/// The original trimmed spelling is retained for display (for example, 5.07).
public struct FirmwareVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    private let components: [UInt64]

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 40 else { return nil }
        let digits = trimmed.first == "v" || trimmed.first == "V" ? String(trimmed.dropFirst()) : trimmed
        let pieces = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count), pieces.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let values = pieces.compactMap { UInt64($0) }
        guard values.count == pieces.count else { return nil }
        rawValue = trimmed
        components = values
    }

    public var description: String { rawValue }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
    public func hash(into hasher: inout Hasher) {
        var canonical = components
        while canonical.count > 1 && canonical.last == 0 { canonical.removeLast() }
        hasher.combine(canonical)
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = Self(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid numeric firmware version")
        }
        self = parsed
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum FirmwareReleaseComponent: String, Codable, Sendable {
    case main, bluetooth, package

    var label: String {
        switch self {
        case .main: "Main firmware"
        case .bluetooth: "Bluetooth firmware"
        case .package: "Main + Bluetooth package"
        }
    }
}

public struct FirmwareCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let modelCodes: [String]
    public let component: FirmwareReleaseComponent
    public var componentLabel: String { component.label }
    public let officialPage: URL
    public let bundledVersion: FirmwareVersion
    /// Date a bundled advisory snapshot was reviewed, not a live network check.
    public let bundledReviewedAt: Date
}

public enum FirmwareCatalog {
    /// Advisory model coverage. This does not grant firmware installation support.
    public static let entries: [FirmwareCatalogEntry] = {
        let date = ISO8601DateFormatter()
        let initial = date.date(from: "2026-11-18T00:00:00Z")!
        let expanded = date.date(from: "2026-11-21T00:00:00Z")!
        func release(_ model: String, _ name: String, _ code: String, _ page: Int, _ version: String,
            _ component: FirmwareReleaseComponent = .main) -> FirmwareCatalogEntry {
            FirmwareCatalogEntry(id: "\(model)-\(component.rawValue)", displayName: name, modelCodes: [code],
                component: component, officialPage: URL(string: "https://www.gulikit.com/newsinfo/\(page).html")!,
                bundledVersion: FirmwareVersion(version)!, bundledReviewedAt: expanded)
        }
        return [
            FirmwareCatalogEntry(id: "ns58-main", displayName: "Elves 2", modelCodes: ["NS58"],
                component: .main, officialPage: URL(string: "https://www.gulikit.com/newsinfo/1071651.html")!,
                bundledVersion: FirmwareVersion("3.7")!, bundledReviewedAt: initial),
            FirmwareCatalogEntry(id: "ns59-main", displayName: "Elves 2 Pro", modelCodes: ["NS59"],
                component: .main, officialPage: URL(string: "https://www.gulikit.com/newsinfo/1050198.html")!,
                bundledVersion: FirmwareVersion("5.8")!, bundledReviewedAt: initial),
            FirmwareCatalogEntry(id: "ns39-main", displayName: "KK3 Max", modelCodes: ["NS39"],
                component: .main, officialPage: URL(string: "https://www.gulikit.com/newsinfo/887152.html")!,
                bundledVersion: FirmwareVersion("5.9")!, bundledReviewedAt: initial),
            FirmwareCatalogEntry(id: "ns38-main", displayName: "KK3 Pro", modelCodes: ["NS38"],
                component: .main, officialPage: URL(string: "https://www.gulikit.com/newsinfo/887152.html")!,
                bundledVersion: FirmwareVersion("5.8")!, bundledReviewedAt: initial),
            release("es", "ES", "ES", 1076221, "4.8"),
            release("es-pro", "ES Pro", "ES Pro", 1076221, "4.8"),
            release("es-max", "ES Max", "ES Max", 1076221, "4.8"),
            release("ns68", "TT Pro", "NS68", 3137265, "8.1.05", .package),
            release("ns69", "TT Max", "NS69", 3137265, "8.1.05", .package),
            release("ns37", "KK3", "NS37", 998404, "3.23", .bluetooth),
            release("ns09t", "KK2T", "NS09T", 1050207, "5.8"),
        ]
    }()
}

public enum FirmwareCatalogSource: String, Codable, Sendable { case live, cache, bundled }
public enum FirmwareCatalogStatus: String, Codable, Sendable { case fresh, stale, refreshFailed, bundled }
public enum FirmwareVersionAdvice: String, Codable, Sendable, Equatable {
    case newerAvailable, upToDate, installedNewer, unknown
}

public struct FirmwareCatalogCheck: Codable, Sendable {
    public let entryID: String
    public let latestVersion: FirmwareVersion?
    public let checkedAt: Date?
    public let sourceURL: URL
    public let source: FirmwareCatalogSource
    public let status: FirmwareCatalogStatus
    public let failure: String?
    public let lastAttemptAt: Date?
    /// An otherwise valid article reading did not cover every first-page
    /// candidate. Its version is advisory, not evidence of being up to date.
    public let discoveryWarning: String?

    /// Fresh here means a successful official-page observation within 24 hours.
    /// A failed refresh or bundled-only record never produces "up to date".
    public var allowsCurrentComparison: Bool {
        status == .fresh && source != .bundled && failure == nil && discoveryWarning == nil
            && checkedAt != nil && latestVersion != nil
    }
    /// Re-evaluate time when displaying a retained result. A result can outlive
    /// the window/check that originally assigned its `.fresh` status.
    public func isCurrent(at now: Date) -> Bool {
        guard allowsCurrentComparison, let checkedAt else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age < FirmwareCatalogService.refreshInterval
    }
    public func advice(installed: String, now: Date = Date()) -> FirmwareVersionAdvice {
        guard FirmwareCatalog.entries.first(where: { $0.id == entryID })?.component == .main,
              isCurrent(at: now), let latestVersion, let current = FirmwareVersion(installed) else { return .unknown }
        if current < latestVersion { return .newerAvailable }
        if current > latestVersion { return .installedNewer }
        return .upToDate
    }
}

public enum FirmwareCatalogError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public enum FirmwareCatalogParser {
    public static let maxPageBytes = 512 * 1024
    private static let codeBearingMainEntries: Set<String> = ["ns58-main", "ns59-main", "ns38-main", "ns39-main"]

    /// Select the first explicit release heading for this model. GuliKit keeps
    /// older headings below the current release. A shared NS38/NS39 heading
    /// applies to both, but an NS39-only release must never advance NS38.
    public static func parse(_ data: Data, for entry: FirmwareCatalogEntry) throws -> FirmwareVersion {
        guard !data.isEmpty, data.count <= maxPageBytes, let html = String(data: data, encoding: .utf8) else {
            throw FirmwareCatalogError.invalid("Official firmware page is empty, too large, or not UTF-8")
        }
        var text = replace(html, pattern: #"(?is)<(head|title|script|style|template|noscript|nav|footer)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, with: " ")
        let usesCodeBearingHeading = codeBearingMainEntries.contains(entry.id)
        if !usesCodeBearingHeading {
            // The site repeats the listing title as an h1 (sometimes with a
            // date) outside the article release text. Require an explicit
            // model and component heading in the body, not the page headline.
            text = replace(text, pattern: #"(?is)<h1\b[^>]*>.*?</h1\s*>"#, with: "\n")
        }
        text = replace(text, pattern: "(?i)<br\\b[^>]*>|</(?:p|div|h[1-6]|li|section|article|title)\\s*>", with: "\n")
        text = replace(text, pattern: "<[^>]+>", with: " ")
        text = decodeEntities(text)
        let normalized = text.lowercased()
        if ["too many requests", "verify you are human", "complete the captcha", "验证码"].contains(where: normalized.contains) {
            throw FirmwareCatalogError.invalid("Official website returned a verification or rate-limit page")
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !usesCodeBearingHeading {
                if let release = FirmwareReleaseHeading.parse(line, listing: false), release.matches(entry) {
                    return release.version
                }
                continue
            }
            guard line.count <= 250, line.lowercased().contains("firmware"),
                  entry.modelCodes.contains(where: { code in
                      line.range(of: "(?i)(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: code) + "(?![A-Z0-9])",
                          options: .regularExpression) != nil
                  }) else { continue }
            // These entries cover main-controller firmware only. A shared page
            // must not silently substitute a radio/adapter/secondary-CPU image.
            if line.range(of: "(?i)\\b(?:BT|Bluetooth|CPU\\s*\\d*|receiver|adapter|dongle)\\b", options: .regularExpression) != nil {
                continue
            }
            let regex = try NSRegularExpression(pattern: "(?i)(?<![A-Z0-9])v\\s*([0-9]+(?:\\.[0-9]+){1,3})(?=\\s*(?:Firmware\\b|[:：]|$))")
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: line),
                  let version = FirmwareVersion(String(line[range])) else {
                throw FirmwareCatalogError.invalid("Unrecognized or ambiguous firmware heading for \(entry.modelCodes.joined(separator: "/"))")
            }
            return version
        }
        throw FirmwareCatalogError.invalid("No explicit current firmware heading for \(entry.modelCodes.joined(separator: "/")); website layout may have changed")
    }

    private static func replace(_ string: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        return regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: replacement)
    }
    static func decodeEntities(_ string: String) -> String {
        var result = string
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">"] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let numberRange = Range(match.range(at: 1), in: result) else { continue }
                let number = String(result[numberRange])
                let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = UnicodeScalar(value) { result.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return result
    }
}
