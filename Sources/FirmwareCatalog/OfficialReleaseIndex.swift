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
        let titlePattern = try NSRegularExpression(pattern: #"(?i)^(.+?)\s+v\s*[0-9]+(?:\.[0-9]+){1,3}\s+firmware\b(?:\s*[-–—]\s*[0-9]{4}[.\-/][0-9]{1,2}[.\-/][0-9]{1,2})?\s*$"#)
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
            guard title.count <= 250, let match = titlePattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let modelRange = Range(match.range(at: 1), in: title),
                  modelIDs(in: String(title[modelRange])).contains(entry.id) else { continue }
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

    private static func modelIDs(in text: String) -> Set<String> {
        var prefix = text.lowercased()
        if prefix.hasPrefix("gulikit ") { prefix.removeFirst("gulikit ".count) }
        let parts = prefix.split(whereSeparator: { "\\/,&+|".contains($0) })
        var ids = Set<String>()
        for part in parts {
            let key = part.filter { !$0.isWhitespace && !"-–—()\"'“”".contains($0) }
            switch key {
            case "elves2", "elves2ns58", "ns58elves2", "ns58": ids.insert("ns58-main")
            case "elves2pro", "elves2prons59", "ns59elves2pro", "ns59": ids.insert("ns59-main")
            case "kk3max", "kk3maxns39", "ns39kk3max", "ns39": ids.insert("ns39-main")
            case "kk3pro", "kk3prons38", "ns38kk3pro", "ns38": ids.insert("ns38-main")
            default: return [] // Do not guess mixed/unknown component titles.
            }
        }
        return ids
    }
}
