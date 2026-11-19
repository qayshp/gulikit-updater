import Foundation

public actor FirmwareCatalogService {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    public static let failureBackoff: TimeInterval = 5 * 60
    private let cacheURL: URL?
    private let fetch: Fetch
    private let indexFetch: Fetch?
    private var records: [String: Record]
    // HTTP/transport failures are shared by every model using this page.
    private var failures: [URL: Failure] = [:]
    // A missing model heading does not invalidate another model on that page.
    private var parseFailures: [String: Failure] = [:]
    private var recentPages: [URL: Page] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]

    private struct Record: Codable, Sendable {
        let version: FirmwareVersion
        let checkedAt: Date
        let sourceURL: URL
        let discoveryAttemptedAt: Date?
        let discoveryWarning: String?
    }
    private struct Cache: Codable {
        let schemaVersion: Int
        let records: [String: Record]
        let failures: [String: Failure]?
        let parseFailures: [String: Failure]?
    }
    private struct Failure: Codable {
        let attemptedAt: Date
        let message: String
        var discoveryWarning: String? = nil
    }
    private struct Page { let data: Data; let checkedAt: Date }

    /// Supplying a custom article fetcher does not implicitly make HTTP requests
    /// to the index. Inject both fetchers to exercise discovery independently.
    public init(cacheURL: URL? = nil, fetch: Fetch? = nil, indexFetch: Fetch? = nil) {
        self.cacheURL = cacheURL
        self.fetch = fetch ?? { url in try await Self.fetchOfficialPage(url) }
        self.indexFetch = indexFetch ?? (fetch == nil ? Self.fetchOfficialIndex : nil)
        let saved = Self.loadCache(cacheURL)
        records = saved.records
        failures = saved.failures
        parseFailures = saved.parseFailures
    }

    /// No network request is made by this method, including for missing caches.
    public func cachedCheck(entry: FirmwareCatalogEntry, now: Date = Date()) -> FirmwareCatalogCheck {
        let failure = storedFailure(entry: entry, now: now)
        return result(entry: entry, now: now, source: .cache, failure: failure)
    }

    /// Force skips the successful-check interval; the failed-attempt backoff still
    /// applies. One shared official page is fetched once for NS38/NS39 batches.
    public func check(entry: FirmwareCatalogEntry, force: Bool = false, now: Date = Date()) async -> FirmwareCatalogCheck {
        guard FirmwareCatalog.entries.contains(entry), Self.isAllowedPageURL(entry.officialPage) else {
            return FirmwareCatalogCheck(entryID: entry.id, latestVersion: nil, checkedAt: nil,
                sourceURL: entry.officialPage, source: .bundled, status: .refreshFailed,
                failure: "Unknown official catalog entry", lastAttemptAt: nil, discoveryWarning: nil)
        }
        if let failure = storedFailure(entry: entry, now: now), now.timeIntervalSince(failure.attemptedAt) >= 0,
           now.timeIntervalSince(failure.attemptedAt) < Self.failureBackoff {
            return result(entry: entry, now: now, source: .cache, failure: failure)
        }
        let previous = validRecord(entry: entry, now: now)
        if let previous, storedFailure(entry: entry, now: now) == nil {
            if let attempted = previous.discoveryAttemptedAt, previous.discoveryWarning != nil,
               now.timeIntervalSince(attempted) < Self.failureBackoff {
                return result(entry: entry, now: now, source: .cache, failure: nil)
            }
            if !force, previous.discoveryWarning == nil,
               (indexFetch == nil || previous.discoveryAttemptedAt != nil),
               now.timeIntervalSince(previous.checkedAt) < Self.refreshInterval {
                return result(entry: entry, now: now, source: .cache, failure: nil)
            }
        }
        var candidateURLs = [URL]()
        var discoveryWarning: String?
        var indexCheckedAt: Date?
        if let indexFetch {
            do {
                let index = try await checkedPage(OfficialReleaseIndex.url, now: now, using: indexFetch)
                let candidates = try OfficialReleaseIndex.candidates(in: index.data, for: entry)
                candidateURLs = candidates.pages
                indexCheckedAt = index.checkedAt
                if candidates.incomplete || candidates.pages.isEmpty {
                    discoveryWarning = "First-page release discovery is incomplete for \(entry.displayName)."
                }
            } catch {
                discoveryWarning = "Could not check GuliKit’s download index: \(error.localizedDescription)"
            }
        }

        // Known and previously validated sources remain fallbacks. Do not
        // assign a new source or version until its own body matches this model.
        var sources = [entry.officialPage]
        for url in candidateURLs + [previous?.sourceURL].compactMap({ $0 }) where !sources.contains(url) {
            sources.append(url)
        }
        var best: (version: FirmwareVersion, date: Date, url: URL)?
        var articleError: String?
        for url in sources {
            do {
                let page = try await checkedPage(url, now: now, using: fetch)
                let version = try FirmwareCatalogParser.parse(page.data, for: entry)
                if best.map({ version > $0.version }) ?? true {
                    best = (version, page.checkedAt, url)
                }
            } catch {
                articleError = articleError ?? String(error.localizedDescription.prefix(512))
            }
        }
        if sources.count > 1, let articleError, discoveryWarning == nil {
            discoveryWarning = "One or more release articles could not be verified for \(entry.displayName): \(articleError)"
        }
        discoveryWarning = discoveryWarning.map { String($0.prefix(512)) }
        guard let best else {
            let failure = Failure(attemptedAt: now, message: articleError ?? "No official release article was verified",
                discoveryWarning: discoveryWarning)
            parseFailures[entry.id] = failure
            persistCache()
            return result(entry: entry, now: now, source: .cache, failure: failure)
        }
        parseFailures.removeValue(forKey: entry.id)
        if let previous, discoveryWarning != nil, previous.version > best.version {
            records[entry.id] = Record(version: previous.version, checkedAt: previous.checkedAt, sourceURL: previous.sourceURL,
                discoveryAttemptedAt: now, discoveryWarning: discoveryWarning)
            persistCache()
            return result(entry: entry, now: now, source: .cache, failure: nil)
        }
        let verifiedAt = indexCheckedAt.map { min($0, best.date) } ?? best.date
        records[entry.id] = Record(version: best.version, checkedAt: verifiedAt, sourceURL: best.url,
            discoveryAttemptedAt: indexFetch == nil ? nil : now, discoveryWarning: discoveryWarning)
        persistCache()
        return result(entry: entry, now: now, source: .live, failure: nil)
    }

    private func checkedPage(_ url: URL, now: Date, using fetcher: @escaping Fetch) async throws -> Page {
        if let failure = failures[url], now.timeIntervalSince(failure.attemptedAt) >= 0,
           now.timeIntervalSince(failure.attemptedAt) < Self.failureBackoff {
            throw FirmwareCatalogError.invalid(failure.message)
        }
        if let recent = recentPages[url], Self.canReuse(recent, at: now, url: url) { return recent }

        let task: Task<Data, Error>
        if let pending = inFlight[url] { task = pending }
        else {
            task = Task { try await fetcher(url) }
            inFlight[url] = task
        }
        defer { inFlight.removeValue(forKey: url) }
        do {
            let data = try await task.value
            guard !data.isEmpty, data.count <= FirmwareCatalogParser.maxPageBytes else {
                throw FirmwareCatalogError.invalid("Official page is empty or exceeds the size limit")
            }
            // Save before parsing so one model's missing heading does not
            // invalidate the shared index/article or cause another request.
            let page = Page(data: data, checkedAt: now)
            recentPages[url] = page
            // Keep discovered-article reuse bounded across successive index revisions.
            if recentPages.count > 24 {
                recentPages = recentPages.filter { Self.canReuse($0.value, at: now, url: $0.key) }
            }
            failures.removeValue(forKey: url)
            return page
        } catch {
            failures[url] = Failure(attemptedAt: now, message: String(error.localizedDescription.prefix(512)))
            persistCache()
            throw error
        }
    }

    private static func canReuse(_ page: Page, at now: Date, url: URL) -> Bool {
        let age = now.timeIntervalSince(page.checkedAt)
        // The index is shared across a multi-model batch; a few slow article
        // responses should not require requesting it again.
        return age >= 0 && age < (url == OfficialReleaseIndex.url ? 5 * 60 : 30)
    }

    private func storedFailure(entry: FirmwareCatalogEntry, now: Date) -> Failure? {
        [indexFetch == nil ? failures[entry.officialPage] : nil, parseFailures[entry.id]].compactMap { $0 }
            .filter { $0.attemptedAt <= now }
            .max(by: { $0.attemptedAt < $1.attemptedAt })
    }

    private func validRecord(entry: FirmwareCatalogEntry, now: Date) -> Record? {
        guard let record = records[entry.id], record.checkedAt <= now,
              record.discoveryAttemptedAt.map({ $0 <= now }) ?? true else { return nil }
        return record
    }
    private func result(entry: FirmwareCatalogEntry, now: Date, source: FirmwareCatalogSource, failure: Failure?) -> FirmwareCatalogCheck {
        let record = validRecord(entry: entry, now: now)
        let actualSource: FirmwareCatalogSource = record == nil ? .bundled : source
        let status: FirmwareCatalogStatus
        if failure != nil { status = .refreshFailed }
        else if let record { status = now.timeIntervalSince(record.checkedAt) < Self.refreshInterval ? .fresh : .stale }
        else { status = .bundled }
        var warning = failure?.discoveryWarning ?? record?.discoveryWarning
        if indexFetch != nil, let record, record.discoveryAttemptedAt == nil, warning == nil {
            warning = "The cached article was checked before release discovery was available."
        }
        return FirmwareCatalogCheck(entryID: entry.id, latestVersion: record?.version ?? entry.bundledVersion,
            checkedAt: record?.checkedAt, sourceURL: record?.sourceURL ?? entry.officialPage, source: actualSource,
            status: status, failure: failure?.message,
            lastAttemptAt: failure?.attemptedAt ?? record?.discoveryAttemptedAt ?? record?.checkedAt,
            discoveryWarning: warning)
    }
    private static func loadCache(_ url: URL?) -> (records: [String: Record], failures: [URL: Failure], parseFailures: [String: Failure]) {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, size <= 128 * 1024, let data = try? Data(contentsOf: url),
              data.count <= 128 * 1024 else { return ([:], [:], [:]) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(Cache.self, from: data), [1, 2, 3].contains(cache.schemaVersion) else { return ([:], [:], [:]) }
        let records = cache.records.filter { id, record in
            guard let entry = FirmwareCatalog.entries.first(where: { $0.id == id }),
                  record.checkedAt.timeIntervalSince1970.isFinite, record.checkedAt.timeIntervalSince1970 > 0,
                  (record.discoveryWarning?.count ?? 0) <= 512 else { return false }
            if let attempted = record.discoveryAttemptedAt {
                guard cache.schemaVersion == 3, attempted.timeIntervalSince1970.isFinite,
                      attempted >= record.checkedAt else { return false }
                return canonicalArticleURL(record.sourceURL) == record.sourceURL
            }
            return record.sourceURL == entry.officialPage
        }
        var failures: [URL: Failure] = [:]
        // Version 1 mixed HTTP and parsing failures by URL. Retain its valid
        // observations but discard those ambiguous failure records on migration.
        for (rawURL, failure) in cache.schemaVersion >= 2 ? cache.failures ?? [:] : [:] {
            guard let url = URL(string: rawURL),
                  isAllowedPageURL(url) || (cache.schemaVersion == 3 && (isOfficialArticleURL(url) || url == OfficialReleaseIndex.url)),
                  failure.attemptedAt.timeIntervalSince1970.isFinite, failure.attemptedAt.timeIntervalSince1970 > 0,
                  failure.message.count <= 512 else { continue }
            failures[url] = failure
        }
        let parseFailures = (cache.parseFailures ?? [:]).filter { id, failure in
            FirmwareCatalog.entries.contains(where: { $0.id == id })
                && failure.attemptedAt.timeIntervalSince1970.isFinite && failure.attemptedAt.timeIntervalSince1970 > 0
                && failure.message.count <= 512 && (failure.discoveryWarning?.count ?? 0) <= 512
        }
        return (records, failures, parseFailures)
    }
    private func persistCache() {
        guard let cacheURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recentFailures = failures.sorted { $0.value.attemptedAt > $1.value.attemptedAt }.prefix(24)
        let savedFailures = Dictionary(uniqueKeysWithValues: recentFailures.map { ($0.key.absoluteString, $0.value) })
        guard let data = try? encoder.encode(Cache(schemaVersion: 3, records: records, failures: savedFailures,
            parseFailures: parseFailures)),
              data.count <= 128 * 1024 else { return }
        // Cache failure does not turn a successful official observation into an
        // installation decision. All catalog data remains advisory only.
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch { /* The in-memory advisory result is still usable. */ }
    }

    public static func isAllowedPageURL(_ url: URL) -> Bool {
        isOfficialArticleURL(url)
            && FirmwareCatalog.entries.contains(where: { $0.officialPage.path == url.path })
    }
    /// Safe shape for a link returned from a verified catalog result. This
    /// alone does not establish that a URL has been discovered or verified.
    public static func isOfficialArticleURL(_ url: URL) -> Bool {
        guard let parts = officialURLParts(url) else { return false }
        return parts.percentEncodedPath.range(of: #"^/newsinfo/[0-9]{1,12}\.html$"#, options: .regularExpression) != nil
    }

    static func canonicalArticleURL(_ url: URL) -> URL? {
        guard isOfficialArticleURL(url) else { return nil }
        return URL(string: "https://www.gulikit.com" + url.path)
    }

    private static func officialURLParts(_ url: URL) -> URLComponents? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", ["www.gulikit.com", "gulikit.com"].contains(parts.host ?? ""),
              parts.port == nil || parts.port == 443, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        return parts
    }

    fileprivate static func isOfficialIndexURL(_ url: URL) -> Bool {
        guard let parts = officialURLParts(url) else { return false }
        return ["/download/", "/download"].contains(parts.percentEncodedPath.lowercased())
    }

    private static func fetchOfficialIndex(_ url: URL) async throws -> Data {
        guard url == OfficialReleaseIndex.url else { throw FirmwareCatalogError.invalid("Unrecognized official download index URL") }
        return try await fetch(.page(url))
    }
    private static func fetchOfficialPage(_ url: URL) async throws -> Data {
        try await resolveOfficialPage(url, fetch: fetch)
    }

    static func resolveOfficialPage(_ url: URL, fetch: (OfficialReleaseResource) async throws -> Data) async throws -> Data {
        // Called only for built-in or index-vetted (or previously verified)
        // article paths. The shape check also protects the redirect/CDN steps.
        guard isOfficialArticleURL(url) else { throw FirmwareCatalogError.invalid("Unrecognized official firmware URL") }
        let html = try await fetch(.page(url))
        // The vendor also serves a small acceleration shell. Its public body
        // script contains the article as one escaped HTML string. Read only
        // that same article's allowlisted resource, never run a script.
        guard let bodyURL = try OfficialReleaseBody.resourceURL(in: html, for: url) else { return html }
        let body = try await fetch(.body(bodyURL, page: url))
        return try OfficialReleaseBody.decode(body)
    }

    private static func fetch(_ resource: OfficialReleaseResource) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration, delegate: OfficialPagePolicy(resource: resource), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: resource.url)
        request.setValue("GuliKitUpdater/0.1 (firmware release check)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FirmwareCatalogError.invalid("Official firmware page returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FirmwareCatalogError.invalid("Official firmware page returned HTTP \(http.statusCode); browser verification or a later check may be needed")
        }
        guard let finalURL = http.url, resource.allows(finalURL),
              resource.mimeTypes.contains(http.mimeType ?? "") else {
            throw FirmwareCatalogError.invalid("Official firmware resource returned an unexpected URL or content type")
        }
        guard response.expectedContentLength <= Int64(FirmwareCatalogParser.maxPageBytes) else {
            throw FirmwareCatalogError.invalid("Official firmware page exceeds the size limit")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < FirmwareCatalogParser.maxPageBytes else {
                throw FirmwareCatalogError.invalid("Official firmware page exceeds the size limit")
            }
            data.append(byte)
        }
        return data
    }
}

enum OfficialReleaseResource: Sendable {
    case page(URL)
    case body(URL, page: URL)

    var url: URL {
        switch self {
        case .page(let url), .body(let url, _): url
        }
    }
    var mimeTypes: [String] {
        switch self {
        case .page: ["text/html", "application/xhtml+xml"]
        case .body: ["application/javascript", "text/javascript"]
        }
    }
    func allows(_ candidate: URL) -> Bool {
        switch self {
        case .page(let url):
            if FirmwareCatalogService.isOfficialIndexURL(url) { FirmwareCatalogService.isOfficialIndexURL(candidate) }
            else { FirmwareCatalogService.isOfficialArticleURL(candidate) && candidate.path == url.path }
        case .body(let url, let page):
            candidate == url && OfficialReleaseBody.isAllowedResourceURL(candidate, for: page)
        }
    }
}

private final class OfficialPagePolicy: NSObject, URLSessionTaskDelegate {
    private let resource: OfficialReleaseResource
    init(resource: OfficialReleaseResource) { self.resource = resource }

    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Refuse all redirects for the exact pinned CDN resource.
        let allowed: Bool
        if case .page = resource { allowed = request.url.map(resource.allows) ?? false }
        else { allowed = false }
        completionHandler(allowed ? request : nil)
    }
}
