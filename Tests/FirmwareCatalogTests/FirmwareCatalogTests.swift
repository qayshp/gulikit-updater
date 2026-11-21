import Foundation
import Testing
@testable import FirmwareCatalog

private actor FetchCounter {
    private var calls = 0
    func increment() { calls += 1 }
    func count() -> Int { calls }
}

struct FirmwareCatalogTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private let ns58HTML = Data("<html><h1>Elves 2 V3.7 Firmware</h1><p>Elves 2 -NS58&nbsp; V3.7 Firmware:</p><p>Old NS58 V3.4 Firmware:</p></html>".utf8)
    private let kk3HTML = Data("""
        <html><title>KK3Max / KK3Pro V5.9 Firmware</title>
        <p>GuliKit &quot;KK3Max-NS39&quot; <span>V5.9</span> Firmware:</p>
        <p>The KK3 Pro does not require this update.</p>
        <p>GuliKit &quot;KK3Max-NS39&quot; &quot;KK3Pro-NS38&quot; V5.8 Firmware:</p></html>
        """.utf8)

    private func entry(_ id: String) throws -> FirmwareCatalogEntry {
        try #require(FirmwareCatalog.entries.first(where: { $0.id == id }))
    }

    @Test func comparesNumericComponentsAndPreservesSpelling() throws {
        let newer = try #require(FirmwareVersion("3.10"))
        let older = try #require(FirmwareVersion("3.7"))
        #expect(newer > older)
        #expect(FirmwareVersion("3.7") == FirmwareVersion("3.7.0"))
        #expect(FirmwareVersion("5.07")?.rawValue == "5.07")
        #expect(FirmwareVersion("5.07") == FirmwareVersion("5.7"))
        #expect(Set([older, try #require(FirmwareVersion("3.7.0"))]).count == 1)
    }

    @Test func rejectsUnrecognizedVersionNotation() {
        for raw in ["", "3..7", "-3.7", "3.7-beta", "3.7/2026", "３.７", "3.7.0.0.0", "999999999999999999999999.7"] {
            #expect(FirmwareVersion(raw) == nil)
        }
    }

    @Test func separatesKK3ModelsOnSharedPage() throws {
        #expect(try FirmwareCatalogParser.parse(kk3HTML, for: entry("ns39-main")).rawValue == "5.9")
        #expect(try FirmwareCatalogParser.parse(kk3HTML, for: entry("ns38-main")).rawValue == "5.8")
    }

    @Test func recognizesExpandedOfficialBodyHeadings() throws {
        let es = "<p><span>GuliKit ES / ES PRO / ES MAX Controller V4.8&nbsp;Firmware&nbsp; (OTA update available via the app)</span></p>"
        let tt = #"<p><strong>GuliKit TT PRO \ TT MAX V8.1.05 Firmware (OTA update available via the app)</strong></p>"#
        let bluetooth = "<h1>KK3-NS37 BT Firmware V9.9</h1><p>“KK3-NS37” BT Firmware V3.23</p>"
        let kk2t = "<p>KK2T-NS09T&nbsp; V5.8&nbsp;Firmware:</p>"
        let cases: [([String], String, String, FirmwareReleaseComponent)] = [
            (["es-main", "es-pro-main", "es-max-main"], es, "4.8", .main),
            (["ns68-package", "ns69-package"], tt, "8.1.05", .package),
            (["ns37-bluetooth"], bluetooth, "3.23", .bluetooth),
            (["ns09t-main"], kk2t, "5.8", .main),
        ]
        for (ids, fragment, expected, component) in cases {
            for id in ids {
                let model = try entry(id)
                #expect(model.component == component)
                #expect(try FirmwareCatalogParser.parse(Data(fragment.utf8), for: model).rawValue == expected)
            }
        }
    }

    @Test func rejectsModelAndComponentMixupsAndTitleOnlyPages() throws {
        let cases = [
            ("es-main", "<p>ES PRO Controller V9.9 Firmware:</p>"),
            ("es-pro-main", "<p>ES MAX Controller V9.9 Firmware:</p>"),
            ("es-max-main", "<p>ES PRO and ES MAX receiver V9.9 Firmware:</p>"),
            ("es-main", "<h1>ES Controller V9.9 Firmware</h1>"),
            ("ns68-package", "<p>TT PRO V9.9.99 Firmware:</p>"),
            ("ns69-package", #" <p>TT PRO \ TT MAX BT Firmware V9.9.99</p>"#),
            ("ns37-bluetooth", "<p>KK3-NS37 V9.9 Firmware:</p>"),
            ("ns37-bluetooth", "<p>KK3Pro-NS38 BT Firmware V9.9</p>"),
            ("ns09t-main", "<p>KK2T-NS09T Bluetooth Firmware V9.9</p>"),
        ]
        for (id, html) in cases {
            let model = try entry(id)
            #expect(throws: (any Error).self) { try FirmwareCatalogParser.parse(Data(html.utf8), for: model) }
        }
    }

    @Test func aCurrentTTPackageIsNotAnInstalledVersionComparison() async throws {
        let fragment = Data(#"<p>TT PRO \ TT MAX V8.1.05 Firmware:</p>"#.utf8)
        let model = try entry("ns68-package")
        let service = FirmwareCatalogService(fetch: { _ in fragment })
        let result = await service.check(entry: model, now: now)
        #expect(result.source == .live && result.isCurrent(at: now))
        #expect(result.latestVersion?.rawValue == "8.1.05")
        #expect(result.advice(installed: "8.1", now: now) == .unknown)
    }

    @Test func resolvesAcceleratedArticleAndStillSeparatesModels() async throws {
        let page = try entry("ns39-main").officialPage
        let asset = try #require(URL(string: "https://img.website.xin/pubsf/18023/18023503/cdn-static-pages/newsinfo/pc/887152_en-us.nocookie.html.Body.js?version=20261116171917"))
        let other = try #require(URL(string: "https://img.website.xin/other.js"))
        let counter = FetchCounter()
        let html = try await FirmwareCatalogService.resolveOfficialPage(page) { resource in
            await counter.increment()
            switch resource {
            case .page(let url):
                #expect(url == page)
                return Data("<html><body id='smart-body'><script src='\(asset.absoluteString)'></script></body></html>".utf8)
            case .body(let url, let owner):
                #expect(url == asset && owner == page && resource.allows(url))
                #expect(!resource.allows(other))
                return Data(#"document.write('\u003cdiv class=\"w-detail\"\u003e<p>KK3 Max NS39 V5.10 Firmware:</p><p>KK3 Max NS39 / KK3 Pro NS38 V5.8 Firmware:</p></div>');"#.utf8)
            }
        }
        #expect(await counter.count() == 2)
        #expect(try FirmwareCatalogParser.parse(html, for: entry("ns39-main")).rawValue == "5.10")
        #expect(try FirmwareCatalogParser.parse(html, for: entry("ns38-main")).rawValue == "5.8")
    }

    @Test func leavesOrdinaryHTMLUntouched() async throws {
        let page = try entry("ns58-main").officialPage
        let fetched = try await FirmwareCatalogService.resolveOfficialPage(page) { resource in
            #expect(resource.url == page)
            return ns58HTML
        }
        #expect(fetched == ns58HTML)
    }

    @Test func selectsActiveHeadingAndIgnoresScriptAndOtherComponents() throws {
        let html = Data("""
            <html><script>const x = "NS58 V99.9 Firmware:";</script>
            <style>NS58 V98.0 Firmware:</style><p>NS58 BT V5.07 Firmware:</p>
            <p>Elves 2 -NS58&#160; <strong>V3.7</strong> Firmware:</p>
            <p>Elves 2 -NS58 V3.4 Firmware:</p></html>
            """.utf8)
        #expect(try FirmwareCatalogParser.parse(html, for: entry("ns58-main")).rawValue == "3.7")
    }

    @Test func rejectsShellCaptchaMissingAndAmbiguousHeadings() throws {
        let ns58 = try entry("ns58-main")
        for html in [
            "<html><title>Elves 2 V3.7 Firmware</title><script src='page.Body.js'></script></html>",
            "<html><head><title>Elves 2 NS58 V3.7 Firmware:</title></head><script src='page.Body.js'></script></html>",
            "<html><title>Elves 2 NS58 V3.7 Firmware:</title><script src='page.Body.js'></script></html>",
            "<html><p>Verify you are human</p></html>",
            "<html><p>NS59 V5.8 Firmware:</p></html>",
            "<html><p>NS58 V3.7 Firmware: V3.8 Firmware:</p></html>",
            "<html><p>NS58 V3.8-beta Firmware:</p></html>",
            "<html><p>NS58 Bluetooth V5.07 Firmware:</p></html>",
            "<html><p>NS58 Dongle V5.07 Firmware:</p></html>",
            "<html><p>NS58 CPU 2 V5.07 Firmware:</p></html>",
        ] {
            #expect(throws: (any Error).self) {
                try FirmwareCatalogParser.parse(Data(html.utf8), for: ns58)
            }
        }
    }

    @Test func permitsOnlyKnownOfficialPageURLs() throws {
        #expect(FirmwareCatalogService.isAllowedPageURL(try entry("ns58-main").officialPage))
        for text in [
            "http://www.gulikit.com/newsinfo/1071651.html",
            "https://www.gulikit.com.example.com/newsinfo/1071651.html",
            "https://user@www.gulikit.com/newsinfo/1071651.html",
            "https://www.gulikit.com/newsinfo/other.html",
            "https://www.gulikit.com/newsinfo/1071651.html?version=9.9",
            "https://www.gulikit.com/newsinfo/1071651.html#other",
        ] {
            #expect(!FirmwareCatalogService.isAllowedPageURL(try #require(URL(string: text))))
        }
    }

    @Test func bundledFallbackIsNeverReportedAsCurrent() async throws {
        let counter = FetchCounter()
        let html = ns58HTML
        let service = FirmwareCatalogService(fetch: { _ in await counter.increment(); return html })
        let result = await service.cachedCheck(entry: try entry("ns58-main"), now: now)
        #expect(result.source == .bundled)
        #expect(result.status == .bundled)
        #expect(result.checkedAt == nil)
        #expect(result.latestVersion?.rawValue == "3.7")
        #expect(!result.allowsCurrentComparison)
        #expect(result.advice(installed: "3.7", now: now) == .unknown)
        #expect(await counter.count() == 0)
    }

    @Test func successfulRefreshIsCachedFor24Hours() async throws {
        let counter = FetchCounter()
        let html = ns58HTML
        let service = FirmwareCatalogService(fetch: { _ in await counter.increment(); return html })
        let model = try entry("ns58-main")
        let first = await service.check(entry: model, now: now)
        #expect(first.source == .live && first.status == .fresh)
        #expect(first.checkedAt == now)
        #expect(first.advice(installed: "3.6", now: now) == .newerAvailable)
        #expect(first.advice(installed: "3.7", now: now) == .upToDate)
        #expect(first.advice(installed: "3.8", now: now) == .installedNewer)
        #expect(!first.isCurrent(at: now.addingTimeInterval(-1)))
        #expect(first.isCurrent(at: now.addingTimeInterval(86_399)))
        #expect(!first.isCurrent(at: now.addingTimeInterval(86_400)))
        #expect(first.advice(installed: "3.7", now: now.addingTimeInterval(86_400)) == .unknown)
        #expect(first.advice(installed: "3.7", now: now.addingTimeInterval(-1)) == .unknown)
        let second = await service.check(entry: model, now: now.addingTimeInterval(60))
        #expect(second.source == .cache && second.allowsCurrentComparison)
        #expect(await counter.count() == 1)
        let stale = await service.cachedCheck(entry: model, now: now.addingTimeInterval(86_401))
        #expect(stale.status == .stale)
        #expect(stale.advice(installed: "3.7", now: now.addingTimeInterval(86_401)) == .unknown)
    }

    @Test func failedRefreshPreservesLastObservationAndBacksOffEvenWhenForced() async throws {
        let counter = FetchCounter()
        let html = ns58HTML
        let service = FirmwareCatalogService(fetch: { _ in
            await counter.increment()
            if await counter.count() > 1 { throw FirmwareCatalogError.invalid("HTTP 429") }
            return html
        })
        let model = try entry("ns58-main")
        _ = await service.check(entry: model, now: now)
        let failed = await service.check(entry: model, force: true, now: now.addingTimeInterval(60))
        #expect(failed.status == .refreshFailed && failed.source == .cache)
        #expect(failed.checkedAt == now)
        #expect(failed.latestVersion?.rawValue == "3.7")
        #expect(failed.failure != nil)
        #expect(failed.advice(installed: "3.7", now: now.addingTimeInterval(60)) == .unknown)
        let backoff = await service.check(entry: model, force: true, now: now.addingTimeInterval(61))
        #expect(backoff.status == .refreshFailed)
        #expect(await counter.count() == 2)
    }

    @Test func sharesOneOfficialPageAcrossKK3Profiles() async throws {
        let counter = FetchCounter()
        let html = kk3HTML
        let service = FirmwareCatalogService(fetch: { _ in await counter.increment(); return html })
        let max = await service.check(entry: try entry("ns39-main"), force: true, now: now)
        let pro = await service.check(entry: try entry("ns38-main"), force: true, now: now)
        #expect(max.latestVersion?.rawValue == "5.9")
        #expect(pro.latestVersion?.rawValue == "5.8")
        #expect(await counter.count() == 1)
    }

    @Test(arguments: [("ns38-main", "NS38", "ns39-main"), ("ns39-main", "NS39", "ns38-main")])
    func modelParseFailureDoesNotBlockAnotherModelOnSharedPage(
        validID: String, modelCode: String, absentID: String
    ) async throws {
        let counter = FetchCounter()
        let html = Data("<html><p>GuliKit \(modelCode) V5.8 Firmware:</p></html>".utf8)
        let service = FirmwareCatalogService(fetch: { _ in await counter.increment(); return html })
        let failed = await service.check(entry: try entry(absentID), force: true, now: now)
        #expect(failed.status == .refreshFailed && failed.failure != nil)
        let valid = await service.check(entry: try entry(validID), force: true, now: now)
        #expect(valid.status == .fresh && valid.failure == nil)
        #expect(valid.latestVersion?.rawValue == "5.8")
        let stillFailed = await service.cachedCheck(entry: try entry(absentID), now: now)
        #expect(stillFailed.status == .refreshFailed)
        #expect(await counter.count() == 1)
    }

    @Test func sharedHTTPFailureBacksOffBothKK3Models() async throws {
        let counter = FetchCounter()
        let service = FirmwareCatalogService(fetch: { _ in
            await counter.increment(); throw FirmwareCatalogError.invalid("HTTP 429")
        })
        let max = await service.check(entry: try entry("ns39-main"), force: true, now: now)
        let pro = await service.check(entry: try entry("ns38-main"), force: true, now: now)
        #expect(max.status == .refreshFailed && pro.status == .refreshFailed)
        #expect(max.failure == pro.failure)
        #expect(await counter.count() == 1)
    }

    @Test func modelSpecificParseFailurePersistsWithoutBlockingOtherCachedModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-catalog-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        let counter = FetchCounter()
        let html = Data("<html><p>GuliKit NS38 V5.8 Firmware:</p></html>".utf8)
        let fetch: FirmwareCatalogService.Fetch = { _ in await counter.increment(); return html }
        let service = FirmwareCatalogService(cacheURL: url, fetch: fetch)
        let absent = try entry("ns39-main")
        let valid = try entry("ns38-main")
        _ = await service.check(entry: absent, force: true, now: now)
        _ = await service.check(entry: valid, force: true, now: now)
        let restored = FirmwareCatalogService(cacheURL: url, fetch: fetch)
        let missing = await restored.check(entry: absent, force: true, now: now.addingTimeInterval(1))
        let retained = await restored.check(entry: valid, now: now.addingTimeInterval(1))
        #expect(missing.status == .refreshFailed && missing.failure?.contains("NS39") == true)
        #expect(retained.status == .fresh && retained.failure == nil && retained.source == .cache)
        #expect(await counter.count() == 1)
    }

    @Test func persistsOnlyValidatedPerModelCacheAndRejectsOtherSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-catalog-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/cache/catalog.json")
        let model = try entry("ns58-main")
        let html = ns58HTML
        let service = FirmwareCatalogService(cacheURL: url, fetch: { _ in html })
        _ = await service.check(entry: model, now: now)
        let loaded = FirmwareCatalogService(cacheURL: url)
        let cached = await loaded.cachedCheck(entry: model, now: now.addingTimeInterval(30))
        #expect(cached.source == .cache)
        // This observation predates discovery (the fixture injected only an
        // article fetcher). Retain it but don't claim first-page coverage.
        #expect(cached.discoveryWarning != nil && !cached.allowsCurrentComparison)
        #expect(cached.latestVersion?.rawValue == "3.7")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try #require(object["records"] as? [String: [String: Any]])
        records[model.id]?["sourceURL"] = "https://example.com/newsinfo/1071651.html"
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let invalid = FirmwareCatalogService(cacheURL: url)
        let ignored = await invalid.cachedCheck(entry: model, now: now.addingTimeInterval(30))
        #expect(ignored.source == .bundled && ignored.checkedAt == nil)
    }

    @Test func failedAttemptBackoffSurvivesServiceReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-catalog-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        let counter = FetchCounter()
        let model = try entry("ns58-main")
        let service = FirmwareCatalogService(cacheURL: url, fetch: { _ in
            await counter.increment(); throw FirmwareCatalogError.invalid("HTTP 429")
        })
        let first = await service.check(entry: model, force: true, now: now)
        #expect(first.status == .refreshFailed && first.source == .bundled)
        let reloaded = FirmwareCatalogService(cacheURL: url, fetch: { _ in
            await counter.increment(); throw FirmwareCatalogError.invalid("HTTP 429")
        })
        let second = await reloaded.check(entry: model, force: true, now: now.addingTimeInterval(1))
        #expect(second.status == .refreshFailed && second.lastAttemptAt == now)
        #expect(!second.allowsCurrentComparison)
        #expect(await counter.count() == 1)
    }

    @Test func malformedAndOversizedCachesFallBackWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gulikit-catalog-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        for bytes in [Data("not JSON".utf8), Data(repeating: 0, count: 128 * 1024 + 1)] {
            try bytes.write(to: url)
            let service = FirmwareCatalogService(cacheURL: url)
            let result = await service.cachedCheck(entry: try entry("ns58-main"), now: now)
            #expect(result.source == .bundled && result.status == .bundled)
        }
    }
}
