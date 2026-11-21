import Foundation

/// First-page discovery only. A listing title labels an article candidate; it
/// does not establish either the article's version or its model coverage.
enum OfficialReleaseIndex {
    static let url = URL(string: "https://www.gulikit.com/download/")!
    static let candidateLimit = 2

    struct Candidates {
        let pages: [URL]
        let incomplete: Bool
    }

    static func candidates(in data: Data, for entry: FirmwareCatalogEntry) throws -> Candidates {
        guard !data.isEmpty, data.count <= FirmwareCatalogParser.maxPageBytes,
              let html = String(data: data, encoding: .utf8) else {
            throw FirmwareCatalogError.invalid("Official download index is empty, too large, or not UTF-8")
        }
        let ignored = try NSRegularExpression(pattern: #"(?is)<!--.*?-->|<(head|script|style|template|noscript)\b[^>]*>.*?</\1\s*>"#)
        let body = ignored.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
        let anchors = try NSRegularExpression(pattern: #"(?is)<a\b([^<>]{0,2048})>((?:(?!</?a\b).){0,768}?)</a\s*>"#)
        let attributes = try NSRegularExpression(pattern: #"(?is)\s+([A-Za-z_:][\w:.-]*)\s*=\s*(['"])(.*?)\2"#)
        var pages = [URL]()
        var incomplete = false
        for anchor in anchors.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let attrRange = Range(anchor.range(at: 1), in: body),
                  let textRange = Range(anchor.range(at: 2), in: body) else { continue }
            let rawAttributes = String(body[attrRange])
            var values: [String: String] = [:]
            var duplicates = Set<String>()
            for attr in attributes.matches(in: rawAttributes, range: NSRange(rawAttributes.startIndex..., in: rawAttributes)) {
                guard let name = Range(attr.range(at: 1), in: rawAttributes),
                      let value = Range(attr.range(at: 3), in: rawAttributes) else { continue }
                let key = rawAttributes[name].lowercased()
                if values.updateValue(String(rawAttributes[value]), forKey: key) != nil { duplicates.insert(key) }
            }
            guard values["class"]?.split(whereSeparator: { $0.isWhitespace }).contains("w-list-titlelink") == true,
                  !duplicates.contains("class"),
                  rawAttributes.range(of: #"(?i)\s+hidden(?:\s|=|$)"#, options: .regularExpression) == nil else { continue }
            let rawText = String(body[textRange]).replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let title = FirmwareCatalogParser.decodeEntities(rawText).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard let release = FirmwareReleaseHeading.parse(title, listing: true),
                  release.matches(entry) else { continue }
            guard !duplicates.contains("href"), let href = values["href"],
                  let resolved = URL(string: FirmwareCatalogParser.decodeEntities(href), relativeTo: url)?.absoluteURL,
                  let page = FirmwareCatalogService.canonicalArticleURL(resolved) else {
                incomplete = true
                continue
            }
            guard !pages.contains(page) else { continue }
            if pages.count < candidateLimit { pages.append(page) }
            else { incomplete = true }
        }
        return Candidates(pages: pages, incomplete: incomplete)
    }

}

/// Exact model names, not substring matches (ES must not match ES Pro, and a
/// generic KK3 release must not be attributed to the Max/Pro or vice versa).
/// A listing heading permits a date suffix; body verification does not.
struct FirmwareReleaseHeading {
    let models: Set<String>
    let component: FirmwareReleaseComponent
    let version: FirmwareVersion

    func matches(_ entry: FirmwareCatalogEntry) -> Bool {
        component == entry.component && models.contains(String(entry.id.dropLast(component.rawValue.count + 1)))
    }

    private static let forward = try! NSRegularExpression(
        pattern: #"(?i)^(.+?)\s+v\s*([0-9]+(?:\.[0-9]+){1,3})\s+firmware\s*[:：]?(?:\s*\(OTA update available via the app\))?$"#)
    private static let bluetooth = try! NSRegularExpression(
        pattern: #"(?i)^(.+?)\s+(?:BT|Bluetooth)\s+firmware\s+v\s*([0-9]+(?:\.[0-9]+){1,3})\s*[:：]?$"#)
    private static let bluetoothSuffix = #"(?i)\s+(?:BT|Bluetooth)$"#
    private static let releaseDate = #"\s*[-–—]\s*[0-9]{4}[.\-/][0-9]{1,2}[.\-/][0-9]{1,2}$"#

    static func parse(_ line: String, listing: Bool) -> Self? {
        guard line.count <= 250 else { return nil }
        let heading = listing
            ? line.replacingOccurrences(of: releaseDate, with: "", options: .regularExpression)
            : line
        let range = NSRange(heading.startIndex..., in: heading)
        let reverseBluetooth = bluetooth.firstMatch(in: heading, range: range)
        guard let match = reverseBluetooth ?? forward.firstMatch(in: heading, range: range),
              let modelRange = Range(match.range(at: 1), in: heading),
              let versionRange = Range(match.range(at: 2), in: heading),
              let version = FirmwareVersion(String(heading[versionRange])) else { return nil }
        var modelText = String(heading[modelRange])
        let forwardBluetooth = modelText.range(of: bluetoothSuffix, options: .regularExpression)
        if let forwardBluetooth { modelText.removeSubrange(forwardBluetooth) }
        let models = modelIDs(in: modelText)
        guard !models.isEmpty else { return nil }
        if reverseBluetooth != nil || forwardBluetooth != nil {
            return Self(models: models, component: .bluetooth, version: version)
        }
        if models.contains("ns68") || models.contains("ns69") {
            // Only the explicit dual-model, three-part TT package announcement
            // has been verified. Do not infer separate chip versions from it.
            guard models == ["ns68", "ns69"], version.rawValue.split(separator: ".").count == 3 else { return nil }
            return Self(models: models, component: .package, version: version)
        }
        return Self(models: models, component: .main, version: version)
    }

    private static func modelIDs(in text: String) -> Set<String> {
        var prefix = text.lowercased()
        if prefix.hasPrefix("gulikit ") { prefix.removeFirst("gulikit ".count) }
        let parts = prefix.split(whereSeparator: { "\\/,&+|".contains($0) })
        var ids = Set<String>()
        for part in parts {
            var key = part.filter { !$0.isWhitespace && !"-–—()\"'“”".contains($0) }
            if key.hasSuffix("controller") { key.removeLast("controller".count) }
            switch key {
            case "elves2", "elves2ns58", "ns58elves2", "ns58": ids.insert("ns58")
            case "elves2pro", "elves2prons59", "ns59elves2pro", "ns59": ids.insert("ns59")
            case "kk3max", "kk3maxns39", "ns39kk3max", "ns39": ids.insert("ns39")
            case "kk3pro", "kk3prons38", "ns38kk3pro", "ns38": ids.insert("ns38")
            case "es": ids.insert("es")
            case "espro": ids.insert("es-pro")
            case "esmax": ids.insert("es-max")
            case "ttpro", "ttprons68", "ns68ttpro", "ns68": ids.insert("ns68")
            case "ttmax", "ttmaxns69", "ns69ttmax", "ns69": ids.insert("ns69")
            case "kk3", "kk3ns37", "ns37kk3", "ns37": ids.insert("ns37")
            case "kk2t", "kk2tns09t", "ns09tkk2t", "ns09t": ids.insert("ns09t")
            default: return [] // Do not guess mixed/unknown component titles.
            }
        }
        return ids
    }
}
