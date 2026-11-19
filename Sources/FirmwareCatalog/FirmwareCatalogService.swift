import Foundation

public actor FirmwareCatalogService {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    public static let failureBackoff: TimeInterval = 5 * 60
    private let cacheURL: URL?
    private let fetch: Fetch
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
    }
    private struct Cache: Codable {
        let schemaVersion: Int
        let records: [String: Record]
        let failures: [String: Failure]?
        let parseFailures: [String: Failure]?
    }
    private struct Failure: Codable { let attemptedAt: Date; let message: String }
    private struct Page { let data: Data; let checkedAt: Date }

    public init(cacheURL: URL? = nil, fetch: Fetch? = nil) {
        self.cacheURL = cacheURL
        self.fetch = fetch ?? { url in try await Self.fetchOfficialPage(url) }
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
                failure: "Unknown official catalog entry", lastAttemptAt: nil)
        }
        if let failure = storedFailure(entry: entry, now: now), now.timeIntervalSince(failure.attemptedAt) >= 0,
           now.timeIntervalSince(failure.attemptedAt) < Self.failureBackoff {
            return result(entry: entry, now: now, source: .cache, failure: failure)
        }
        if !force, storedFailure(entry: entry, now: now) == nil, let record = validRecord(entry: entry, now: now),
           now.timeIntervalSince(record.checkedAt) < Self.refreshInterval {
            return result(entry: entry, now: now, source: .cache, failure: nil)
        }
        let page: Page
        do {
            if let recent = recentPages[entry.officialPage], now.timeIntervalSince(recent.checkedAt) >= 0,
               now.timeIntervalSince(recent.checkedAt) < 30 {
                page = recent
            } else {
                let task: Task<Data, Error>
                if let pending = inFlight[entry.officialPage] { task = pending }
                else {
                    let fetcher = fetch
                    let url = entry.officialPage
                    task = Task { try await fetcher(url) }
                    inFlight[entry.officialPage] = task
                }
                do {
                    let bytes = try await task.value
                    inFlight.removeValue(forKey: entry.officialPage)
                    guard !bytes.isEmpty, bytes.count <= FirmwareCatalogParser.maxPageBytes else {
                        throw FirmwareCatalogError.invalid("Official firmware page is empty or exceeds the size limit")
                    }
                    page = Page(data: bytes, checkedAt: now)
                } catch {
                    inFlight.removeValue(forKey: entry.officialPage)
                    throw error
                }
            }
            // Retain the successfully fetched page before parsing any one model.
            // A later model can still use it if this model's heading is absent.
            recentPages[entry.officialPage] = page
            failures.removeValue(forKey: entry.officialPage)
        } catch {
            let failure = Failure(attemptedAt: now, message: String(error.localizedDescription.prefix(512)))
            failures[entry.officialPage] = failure
            persistCache()
            return result(entry: entry, now: now, source: .cache, failure: failure)
        }
        do {
            let version = try FirmwareCatalogParser.parse(page.data, for: entry)
            records[entry.id] = Record(version: version, checkedAt: page.checkedAt, sourceURL: entry.officialPage)
            parseFailures.removeValue(forKey: entry.id)
            persistCache()
            return result(entry: entry, now: now, source: .live, failure: nil)
        } catch {
            let failure = Failure(attemptedAt: now, message: String(error.localizedDescription.prefix(512)))
            parseFailures[entry.id] = failure
            persistCache()
            return result(entry: entry, now: now, source: .cache, failure: failure)
        }
    }

    private func storedFailure(entry: FirmwareCatalogEntry, now: Date) -> Failure? {
        [failures[entry.officialPage], parseFailures[entry.id]].compactMap { $0 }
            .filter { $0.attemptedAt <= now }
            .max(by: { $0.attemptedAt < $1.attemptedAt })
    }

    private func validRecord(entry: FirmwareCatalogEntry, now: Date) -> Record? {
        guard let record = records[entry.id], record.sourceURL == entry.officialPage,
              record.checkedAt <= now else { return nil }
        return record
    }
    private func result(entry: FirmwareCatalogEntry, now: Date, source: FirmwareCatalogSource, failure: Failure?) -> FirmwareCatalogCheck {
        let record = validRecord(entry: entry, now: now)
        let actualSource: FirmwareCatalogSource = record == nil ? .bundled : source
        let status: FirmwareCatalogStatus
        if failure != nil { status = .refreshFailed }
        else if let record { status = now.timeIntervalSince(record.checkedAt) < Self.refreshInterval ? .fresh : .stale }
        else { status = .bundled }
        return FirmwareCatalogCheck(entryID: entry.id, latestVersion: record?.version ?? entry.bundledVersion,
            checkedAt: record?.checkedAt, sourceURL: entry.officialPage, source: actualSource,
            status: status, failure: failure?.message, lastAttemptAt: failure?.attemptedAt ?? record?.checkedAt)
    }
    private static func loadCache(_ url: URL?) -> (records: [String: Record], failures: [URL: Failure], parseFailures: [String: Failure]) {
        guard let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, size <= 128 * 1024, let data = try? Data(contentsOf: url),
              data.count <= 128 * 1024 else { return ([:], [:], [:]) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(Cache.self, from: data), [1, 2].contains(cache.schemaVersion) else { return ([:], [:], [:]) }
        let records = cache.records.filter { id, record in
            FirmwareCatalog.entries.contains(where: { $0.id == id && $0.officialPage == record.sourceURL })
                && record.checkedAt.timeIntervalSince1970.isFinite && record.checkedAt.timeIntervalSince1970 > 0
        }
        var failures: [URL: Failure] = [:]
        // Version 1 mixed HTTP and parsing failures by URL. Retain its valid
        // observations but discard those ambiguous failure records on migration.
        for (rawURL, failure) in cache.schemaVersion == 2 ? cache.failures ?? [:] : [:] {
            guard let url = URL(string: rawURL), FirmwareCatalog.entries.contains(where: { $0.officialPage == url }),
                  failure.attemptedAt.timeIntervalSince1970.isFinite, failure.attemptedAt.timeIntervalSince1970 > 0,
                  failure.message.count <= 512 else { continue }
            failures[url] = failure
        }
        let parseFailures = (cache.parseFailures ?? [:]).filter { id, failure in
            FirmwareCatalog.entries.contains(where: { $0.id == id })
                && failure.attemptedAt.timeIntervalSince1970.isFinite && failure.attemptedAt.timeIntervalSince1970 > 0
                && failure.message.count <= 512
        }
        return (records, failures, parseFailures)
    }
    private func persistCache() {
        guard let cacheURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let savedFailures = Dictionary(uniqueKeysWithValues: failures.map { ($0.key.absoluteString, $0.value) })
        guard let data = try? encoder.encode(Cache(schemaVersion: 2, records: records, failures: savedFailures,
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
        url.scheme == "https" && ["www.gulikit.com", "gulikit.com"].contains(url.host ?? "")
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && FirmwareCatalog.entries.contains(where: { $0.officialPage.path == url.path })
    }
    private static func fetchOfficialPage(_ url: URL) async throws -> Data {
        try await resolveOfficialPage(url, fetch: fetch)
    }

    static func resolveOfficialPage(_ url: URL, fetch: (OfficialReleaseResource) async throws -> Data) async throws -> Data {
        guard isAllowedPageURL(url) else { throw FirmwareCatalogError.invalid("Unrecognized official firmware URL") }
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
            FirmwareCatalogService.isAllowedPageURL(candidate) && candidate.path == url.path
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
