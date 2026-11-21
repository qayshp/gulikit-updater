import Foundation
import Testing
@testable import FirmwareCatalog

private actor DiscoveryRequests {
    private var urls: [URL] = []

    func record(_ url: URL) { urls.append(url) }
    func all() -> [URL] { urls }
}

struct OfficialReleaseIndexTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let newURL = URL(string: "https://www.gulikit.com/newsinfo/9990123.html")!

    private func entry(_ id: String) throws -> FirmwareCatalogEntry {
        try #require(FirmwareCatalog.entries.first(where: { $0.id == id }))
    }

    private func index(_ rows: String...) -> Data {
        Data(("<html><body>" + rows.joined(separator: "\n") + "</body></html>").utf8)
    }

    private func row(_ path: String, _ title: String) -> String {
        #"<a href="\#(path)" target="_self" class="w-list-titlelink">\#(title)</a>"#
    }

    @Test func matchesObservedOfficialTitlesWithoutMixingModelOrFirmwareComponent() throws {
        let html = index(
            row("/newsinfo/1050198.html", "Elves 2 Pro V5.8 Firmware -2026.4.30"),
            row("/newsinfo/887152.html", #"KK3Max \ KK3Pro V5.9 Firmware -2026.3.2"#),
            row("/newsinfo/1071651.html", "Elves 2 V3.7 Firmware -2026.1.6"),
            row("/newsinfo/1076221.html", "ES / ES PRO / ES MAX Controller V4.8 Firmware -2026.11.10"),
            row("/newsinfo/3137265.html", #"GuliKit TT PRO \ TT MAX V8.1.05 Firmware -2026.11.16"#),
            row("/newsinfo/998404.html", "KK3-NS37 BT Firmware V3.23 -2025.02.10"),
            row("/newsinfo/1050207.html", "KK2T V5.8 Firmware -2025.11.28"),
            row("/newsinfo/915900.html", #"KK3Max \ KK3Pro\Elves2 Pro BT Firmware V5.07 -2025.12.10"#),
            row("/newsinfo/126.html", "KK3-NS37 V99.9 Firmware"),
            row("/newsinfo/127.html", "KK2T-NS09T BT Firmware V99.9"),
            row("/newsinfo/128.html", #"TT PRO \ TT MAX BT Firmware V99.9.99"#),
            row("/newsinfo/123.html", "NS58 Bluetooth V9.9 Firmware"),
            "<!--" + row("/newsinfo/124.html", "NS58 V9.9 Firmware") + "-->",
            "<template>" + row("/newsinfo/125.html", "NS59 V9.9 Firmware") + "</template>"
        )
        for model in FirmwareCatalog.entries {
            let found = try OfficialReleaseIndex.candidates(in: html, for: model)
            #expect(found.pages == [model.officialPage])
            #expect(!found.incomplete)
        }
    }

    @Test func recognizesAnESProOnlyListingWithoutAdvancingOtherESModels() throws {
        let html = index(row(newURL.path, "ES PRO Controller V4.9 Firmware -2026.11.21"))
        for id in ["es-main", "es-pro-main", "es-max-main"] {
            let found = try OfficialReleaseIndex.candidates(in: html, for: entry(id))
            #expect(found.pages == (id == "es-pro-main" ? [newURL] : []))
        }
    }

    @Test func limitsCandidateCountAndRejectsUnsafeOrMalformedLinks() throws {
        let model = try entry("ns58-main")
        let html = index(
            row("https://gulikit.com/newsinfo/123.html", "ELVES 2 (NS58) V3.7 Firmware"),
            row("/newsinfo/123.html", "NS58 V3.7 Firmware"),
            row("https://evil.example/newsinfo/666.html", "Elves 2 V9.9 Firmware"),
            row("/newsinfo/777.html?other=1", "NS58 V9.9 Firmware"),
            row("/newsinfo/123%2ehtml", "NS58 V9.9 Firmware"),
            row("/newsinfo/124.html", "NS58 V3.8 Firmware"),
            row("/newsinfo/125.html", "NS58 V3.9 Firmware")
        )
        let found = try OfficialReleaseIndex.candidates(in: html, for: model)
        #expect(found.pages.map(\.path) == ["/newsinfo/123.html", "/newsinfo/124.html"])
        #expect(found.incomplete)
        #expect(FirmwareCatalogService.isOfficialArticleURL(newURL))
        #expect(!FirmwareCatalogService.isAllowedPageURL(newURL))
        #expect(!FirmwareCatalogService.isOfficialArticleURL(URL(string: "https://www.gulikit.com/newsinfo/123.html#part")!))
    }

    @Test func discoversAndVerifiesNewURLButNeverTrustsTheIndexVersion() async throws {
        let model = try entry("ns58-main")
        let requests = DiscoveryRequests()
        let page = newURL
        let html = index(row(page.path, "Elves 2 V99.9 Firmware -2026.11.20"))
        let service = FirmwareCatalogService(fetch: { url in
            await requests.record(url)
            switch url {
            case model.officialPage: return Data("<p>NS58 V3.7 Firmware:</p>".utf8)
            case page: return Data("<p>NS58 V3.8 Firmware:</p>".utf8)
            default: throw FirmwareCatalogError.invalid("Unexpected article URL")
            }
        }, indexFetch: { url in
            await requests.record(url)
            return html
        })
        let result = await service.check(entry: model, force: true, now: now)
        #expect(result.latestVersion?.rawValue == "3.8")
        #expect(result.sourceURL == page && result.source == .live)
        #expect(result.discoveryWarning == nil && result.allowsCurrentComparison)
        #expect(await requests.all() == [OfficialReleaseIndex.url, model.officialPage, page])
    }

    @Test func olderDiscoveredArticleDoesNotReplaceNewerKnownResult() async throws {
        let model = try entry("ns58-main")
        let html = index(row(newURL.path, "NS58 V99.9 Firmware"))
        let service = FirmwareCatalogService(fetch: { url in
            Data("<p>NS58 V\(url == model.officialPage ? "3.7" : "3.4") Firmware:</p>".utf8)
        }, indexFetch: { _ in html })
        let result = await service.check(entry: model, force: true, now: now)
        #expect(result.latestVersion?.rawValue == "3.7")
        #expect(result.sourceURL == model.officialPage && result.allowsCurrentComparison)
    }

    @Test func failedIndexStillChecksKnownArticleWithoutClaimingCurrentCoverage() async throws {
        let model = try entry("ns58-main")
        let requests = DiscoveryRequests()
        let service = FirmwareCatalogService(fetch: { url in
            await requests.record(url)
            return Data("<p>NS58 V3.7 Firmware:</p>".utf8)
        }, indexFetch: { url in
            await requests.record(url)
            throw FirmwareCatalogError.invalid("HTTP 429")
        })
        let result = await service.check(entry: model, force: true, now: now)
        #expect(result.latestVersion?.rawValue == "3.7" && result.source == .live)
        #expect(result.sourceURL == model.officialPage && result.failure == nil)
        #expect(result.discoveryWarning?.contains("HTTP 429") == true)
        #expect(result.advice(installed: "3.7", now: now) == .unknown)
        let repeated = await service.check(entry: model, force: true, now: now.addingTimeInterval(60))
        #expect(repeated.source == .cache && repeated.discoveryWarning == result.discoveryWarning)
        #expect(await requests.all() == [OfficialReleaseIndex.url, model.officialPage])
    }

    @Test func bodyMustMatchExactModelAndSharedIndexAndArticlesAreReused() async throws {
        let max = try entry("ns39-main")
        let pro = try entry("ns38-main")
        let requests = DiscoveryRequests()
        let html = index(row(newURL.path, "KK3Max / KK3Pro V6.1 Firmware"))
        let service = FirmwareCatalogService(fetch: { url in
            await requests.record(url)
            // The new article doesn't actually announce a Pro release.
            if url == max.officialPage {
                return Data("<p>NS39 V5.9 Firmware:</p><p>NS38 V5.8 Firmware:</p>".utf8)
            }
            return Data("<p>NS39 V6.1 Firmware:</p>".utf8)
        }, indexFetch: { url in
            await requests.record(url)
            return html
        })
        let maxResult = await service.check(entry: max, force: true, now: now)
        let proResult = await service.check(entry: pro, force: true, now: now.addingTimeInterval(1))
        #expect(maxResult.latestVersion?.rawValue == "6.1" && maxResult.sourceURL == newURL)
        #expect(maxResult.allowsCurrentComparison)
        #expect(proResult.latestVersion?.rawValue == "5.8" && proResult.sourceURL == pro.officialPage)
        #expect(proResult.discoveryWarning != nil && !proResult.allowsCurrentComparison)
        #expect(await requests.all() == [OfficialReleaseIndex.url, max.officialPage, newURL])
    }

    @Test func persistsVerifiedDiscoveredSourceAndReplaysWithoutNetworking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-discovered-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("catalog.json")
        let model = try entry("ns58-main")
        let html = index(row(newURL.path, "NS58 V3.8 Firmware"))
        let requests = DiscoveryRequests()
        let fetch: FirmwareCatalogService.Fetch = { url in
            await requests.record(url)
            return Data("<p>NS58 V\(url == model.officialPage ? "3.7" : "3.8") Firmware:</p>".utf8)
        }
        let indexFetch: FirmwareCatalogService.Fetch = { url in
            await requests.record(url)
            return html
        }
        let service = FirmwareCatalogService(cacheURL: cache, fetch: fetch, indexFetch: indexFetch)
        _ = await service.check(entry: model, now: now)
        let reloaded = FirmwareCatalogService(cacheURL: cache, fetch: fetch, indexFetch: indexFetch)
        let cached = await reloaded.check(entry: model, now: now.addingTimeInterval(10))
        #expect(cached.sourceURL == newURL && cached.latestVersion?.rawValue == "3.8")
        #expect(cached.source == .cache && cached.allowsCurrentComparison)
        #expect(await requests.all() == [OfficialReleaseIndex.url, model.officialPage, newURL])
    }

    @Test func newlyDiscoveredPageNeedsItsOwnExactCDNArticleID() async throws {
        let page = newURL
        let asset = URL(string: "https://img.website.xin/pubsf/18023/18023503/cdn-static-pages/newsinfo/pc/9990123_en-us.nocookie.html.Body.js?version=123")!
        let wrong = URL(string: "https://img.website.xin/pubsf/18023/18023503/cdn-static-pages/newsinfo/pc/1071651_en-us.nocookie.html.Body.js?version=123")!
        #expect(OfficialReleaseBody.isAllowedResourceURL(asset, for: page))
        #expect(!OfficialReleaseBody.isAllowedResourceURL(wrong, for: page))
        let decoded = try await FirmwareCatalogService.resolveOfficialPage(page) { resource in
            switch resource {
            case .page: return Data("<body id='smart-body'><script src='\(asset.absoluteString)'></script></body>".utf8)
            case .body: return Data("document.write('<p>NS58 V3.8 Firmware:</p>');".utf8)
            }
        }
        #expect(try FirmwareCatalogParser.parse(decoded, for: entry("ns58-main")).rawValue == "3.8")
    }
}
