import Foundation

/// Handles the specific static-page wrapper used by GuliKit's official site.
/// The CDN response is decoded as a string literal; no JavaScript is executed.
enum OfficialReleaseBody {
    private static let host = "img.website.xin"
    private static let pathPrefix = "/pubsf/18023/18023503/cdn-static-pages/newsinfo/pc/"
    private static let maxBytes = FirmwareCatalogParser.maxPageBytes

    static func isAllowedResourceURL(_ url: URL, for page: URL) -> Bool {
        guard FirmwareCatalogService.isAllowedPageURL(page),
              let pageID = pageID(for: page), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == host,
              parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == pathPrefix + pageID + "_en-us.nocookie.html.Body.js",
              let query = parts.percentEncodedQuery,
              query.range(of: "^version=[0-9]{1,20}$", options: .regularExpression) != nil else { return false }
        return true
    }

    /// Returns nil for a normal page without this wrapper. A wrapper-looking
    /// page with an ambiguous or unapproved resource fails closed.
    static func resourceURL(in data: Data, for page: URL) throws -> URL? {
        guard FirmwareCatalogService.isAllowedPageURL(page), !data.isEmpty,
              data.count <= maxBytes, let html = String(data: data, encoding: .utf8) else {
            throw invalid("Invalid official firmware shell or page URL")
        }
        let scriptPattern = #"(?is)<script\b[^>]*\s+src\s*=\s*(["'])(.*?)\1[^>]*>"#
        let scripts = matches(scriptPattern, in: html)
        let candidates = scripts.compactMap { match -> (NSTextCheckingResult, String)? in
            guard let range = Range(match.range(at: 2), in: html) else { return nil }
            let source = String(html[range])
            return source.contains(".Body.js") ? (match, source) : nil
        }
        guard !candidates.isEmpty else {
            if html.contains(".Body.js") { throw invalid("Malformed official firmware body resource") }
            return nil
        }
        guard candidates.count == 1 else { throw invalid("Ambiguous official firmware body resources") }
        let openings = matches(#"(?is)<body\b[^>]*>"#, in: html)
        let closings = matches(#"(?is)</body\s*>"#, in: html)
        guard openings.count == 1, closings.count == 1,
              let openingRange = Range(openings[0].range, in: html),
              String(html[openingRange]).range(of: #"(?i)\s+id\s*=\s*(?:"smart-body"|'smart-body')(?=\s|/?>)"#,
                  options: .regularExpression) != nil,
              NSMaxRange(openings[0].range) <= candidates[0].0.range.location,
              NSMaxRange(candidates[0].0.range) <= closings[0].range.location else {
            throw invalid("Body resource is outside the recognized official page shell")
        }
        guard let url = URL(string: candidates[0].1), isAllowedResourceURL(url, for: page) else {
            throw invalid("Official firmware shell referenced an unapproved body resource")
        }
        return url
    }

    /// Accept only document.write('<one string literal>'); with optional
    /// surrounding whitespace/semicolon. An expression or trailing statement is
    /// rejected, including code after an otherwise valid literal.
    static func decode(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else {
            throw invalid("Official firmware body is empty, too large, or not UTF-8")
        }
        var scanner = LiteralScanner(text: text, limit: maxBytes)
        return try scanner.decode()
    }

    private static func pageID(for url: URL) -> String? {
        guard let match = matches(#"^/newsinfo/([0-9]+)\.html$"#, in: url.path).first,
              let range = Range(match.range(at: 1), in: url.path) else { return nil }
        return String(url.path[range])
    }
    private static func matches(_ pattern: String, in string: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
    }
    private static func invalid(_ message: String) -> FirmwareCatalogError { .invalid(message) }

    private struct LiteralScanner {
        let scalars: [UnicodeScalar]
        let limit: Int
        var offset = 0
        var output = Data()

        init(text: String, limit: Int) {
            scalars = Array(text.unicodeScalars)
            self.limit = limit
        }
        mutating func decode() throws -> Data {
            skipWhitespace()
            try consume("document")
            skipWhitespace(); try consume(".")
            skipWhitespace(); try consume("write")
            skipWhitespace(); try consume("(")
            skipWhitespace(); try consume("'")
            var closed = false
            while offset < scalars.count {
                let scalar = scalars[offset]; offset += 1
                if scalar == "'" { closed = true; break }
                if scalar == "\\" { try escape(); continue }
                guard scalar.value >= 0x20, scalar.value != 0x2028, scalar.value != 0x2029 else {
                    throw OfficialReleaseBody.invalid("Unescaped control character in firmware body literal")
                }
                try append(scalar)
            }
            guard closed else { throw OfficialReleaseBody.invalid("Unterminated firmware body literal") }
            skipWhitespace(); try consume(")"); skipWhitespace()
            if peek == ";" { offset += 1; skipWhitespace() }
            guard offset == scalars.count else {
                throw OfficialReleaseBody.invalid("Executable content follows firmware body literal")
            }
            return output
        }
        private var peek: UnicodeScalar? { offset < scalars.count ? scalars[offset] : nil }
        private mutating func skipWhitespace() {
            while let scalar = peek, CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0xfeff { offset += 1 }
        }
        private mutating func consume(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                guard peek == scalar else { throw OfficialReleaseBody.invalid("Unrecognized firmware body wrapper") }
                offset += 1
            }
        }
        private mutating func append(_ scalar: UnicodeScalar) throws {
            let bytes = String(scalar).utf8
            guard output.count <= limit - bytes.count else {
                throw OfficialReleaseBody.invalid("Decoded firmware body exceeds the size limit")
            }
            output.append(contentsOf: bytes)
        }
        private mutating func escape() throws {
            guard let escaped = peek else { throw OfficialReleaseBody.invalid("Incomplete firmware body escape") }
            offset += 1
            switch escaped {
            case "'", "\"", "\\", "/": try append(escaped)
            case "r": try append("\r")
            case "n": try append("\n")
            case "t": try append("\t")
            case "b": try append("\u{0008}")
            case "f": try append("\u{000c}")
            case "v": try append("\u{000b}")
            case "x":
                let value = try hex(count: 2)
                guard let scalar = UnicodeScalar(value) else { throw OfficialReleaseBody.invalid("Invalid firmware body byte escape") }
                try append(scalar)
            case "u":
                let first = try hex(count: 4)
                if (0xd800...0xdbff).contains(first) {
                    try consume("\\u")
                    let second = try hex(count: 4)
                    guard (0xdc00...0xdfff).contains(second),
                          let scalar = UnicodeScalar(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00) else {
                        throw OfficialReleaseBody.invalid("Invalid UTF-16 surrogate pair in firmware body")
                    }
                    try append(scalar)
                } else {
                    guard !(0xdc00...0xdfff).contains(first), let scalar = UnicodeScalar(first) else {
                        throw OfficialReleaseBody.invalid("Lone UTF-16 surrogate in firmware body")
                    }
                    try append(scalar)
                }
            default: throw OfficialReleaseBody.invalid("Unsupported firmware body escape")
            }
        }
        private mutating func hex(count: Int) throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<count {
                guard let scalar = peek else { throw OfficialReleaseBody.invalid("Truncated firmware body hex escape") }
                let digit: UInt32
                switch scalar.value {
                case 48...57: digit = scalar.value - 48
                case 65...70: digit = scalar.value - 65 + 10
                case 97...102: digit = scalar.value - 97 + 10
                default: throw OfficialReleaseBody.invalid("Invalid firmware body hex escape")
                }
                value = value * 16 + digit; offset += 1
            }
            return value
        }
    }
}
