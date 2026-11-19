import Foundation
import Testing
@testable import FirmwareCatalog

struct OfficialReleaseBodyTests {
    private let page = URL(string: "https://www.gulikit.com/newsinfo/1071651.html")!
    private let resource = "https://img.website.xin/pubsf/18023/18023503/cdn-static-pages/newsinfo/pc/1071651_en-us.nocookie.html.Body.js?version=20261116171917"

    private func shell(_ source: String) -> Data {
        Data("<html><head><title>Elves 2 V3.7 Firmware</title></head><body id='smart-body' area='main'><script src='\(source)'></script><input type='hidden' name='__RequestVerificationToken' value='normal-page-token'/></body></html>".utf8)
    }

    @Test func recognizesExactOfficialShellDespiteNormalVerificationToken() throws {
        let url = try OfficialReleaseBody.resourceURL(in: shell(resource), for: page)
        #expect(url == URL(string: resource))
        #expect(OfficialReleaseBody.isAllowedResourceURL(try #require(url), for: page))
    }

    @Test func normalArticleHasNoBodyResource() throws {
        let data = Data("<html><body><p>Elves 2 -NS58 V3.7 Firmware:</p></body></html>".utf8)
        #expect(try OfficialReleaseBody.resourceURL(in: data, for: page) == nil)
    }

    @Test func rejectsOtherPageHostSitePathHeadAssetAndQuery() throws {
        let bad = [
            resource.replacingOccurrences(of: "https://", with: "http://"),
            resource.replacingOccurrences(of: "img.website.xin", with: "example.com"),
            resource.replacingOccurrences(of: "img.website.xin", with: "img.website.xin.example.com"),
            resource.replacingOccurrences(of: "img.website.xin", with: "user@img.website.xin"),
            resource.replacingOccurrences(of: "img.website.xin", with: "img.website.xin:8443"),
            resource.replacingOccurrences(of: "18023503", with: "18023504"),
            resource.replacingOccurrences(of: "1071651_en-us", with: "1050198_en-us"),
            resource.replacingOccurrences(of: "en-us", with: "zh-cn"),
            resource.replacingOccurrences(of: ".Body.js", with: ".Head.js"),
            resource.replacingOccurrences(of: "version=20261116171917", with: "version=1&other=2"),
            resource.replacingOccurrences(of: "version=20261116171917", with: "version=1&version=2"),
            resource.replacingOccurrences(of: "version=20261116171917", with: "version=abc"),
            resource.replacingOccurrences(of: "?version=20261116171917", with: ""),
            resource + "#fragment",
        ]
        for text in bad {
            #expect(!OfficialReleaseBody.isAllowedResourceURL(try #require(URL(string: text)), for: page))
        }
        let unknownPage = URL(string: "https://www.gulikit.com/newsinfo/9999999.html")!
        #expect(!OfficialReleaseBody.isAllowedResourceURL(try #require(URL(string: resource)), for: unknownPage))
    }

    @Test func rejectsAmbiguousOrUnrecognizedShell() {
        let cases = [
            "<body id='smart-body'><script src='\(resource)'></script><script src='\(resource)'></script></body>",
            "<body><script src='\(resource)'></script></body>",
            "<head><script src='\(resource)'></script></head><body id='smart-body'></body>",
            "<body id='smart-body'><script src='https://example.com/page.Body.js'></script></body>",
            "<body id='smart-body'><script src=\(resource)></script></body>",
            "<body id='smart-body'><script src='\(resource)'></script>",
        ]
        for html in cases {
            #expect(throws: (any Error).self) {
                try OfficialReleaseBody.resourceURL(in: Data(html.utf8), for: page)
            }
        }
    }

    @Test func decodesNormalEscapesWithoutExecutingCode() throws {
        let script = #"document.write('\r\n\t\u003cp title=\"GuliKit\"\u003eNS58 V3.7 Firmware: it\'s \\ / \/\u003c/p\u003e');"#
        let decoded = try OfficialReleaseBody.decode(Data(script.utf8))
        #expect(String(data: decoded, encoding: .utf8) == "\r\n\t<p title=\"GuliKit\">NS58 V3.7 Firmware: it's \\ / /</p>")
        let entry = try #require(FirmwareCatalog.entries.first(where: { $0.id == "ns58-main" }))
        #expect(try FirmwareCatalogParser.parse(decoded, for: entry).rawValue == "3.7")
    }

    @Test func permitsWhitespaceAndOptionalSemicolon() throws {
        for script in [" \n document . write ( 'hello' ) ; \t", "document.write('hello')", "document.write('');"] {
            let data = try OfficialReleaseBody.decode(Data(script.utf8))
            #expect(data == Data((script.contains("hello") ? "hello" : "").utf8))
        }
    }

    @Test func decodesHexAndValidUTF16Pair() throws {
        let script = #"document.write('\x41\u00e9\ud83d\ude00');"#
        #expect(try OfficialReleaseBody.decode(Data(script.utf8)) == Data("Aé😀".utf8))
    }

    @Test func rejectsExecutableWrappersAndTrailingStatements() {
        for script in [
            "document.write('<p>ok</p>');alert('no')",
            "document.write('<p>ok</p>' + other)",
            "document.write(fetch('https://example.com'))",
            "window.document.write('ok');",
            "document.write(`ok`);",
            "document.write(\"ok\");",
            "document.write('ok');/* extra content */",
            "document.write('unterminated)",
            "document.write('line\nbreak');",
        ] {
            #expect(throws: (any Error).self) { try OfficialReleaseBody.decode(Data(script.utf8)) }
        }
    }

    @Test func rejectsInvalidEscapesAndSurrogates() {
        for literal in [#"\uD800"#, #"\uDC00"#, #"\uD800\u0041"#, #"\uD800\x41"#,
            #"\u123"#, #"\x1"#, #"\xGG"#, #"\u{1f600}"#, #"\q"#, #"\1"#] {
            #expect(throws: (any Error).self) {
                try OfficialReleaseBody.decode(Data("document.write('\(literal)');".utf8))
            }
        }
    }

    @Test func rejectsInvalidUTF8AndOversizedResources() {
        for bytes in [Data([0xff]), Data(repeating: 65, count: FirmwareCatalogParser.maxPageBytes + 1)] {
            #expect(throws: (any Error).self) { try OfficialReleaseBody.decode(bytes) }
        }
    }
}
