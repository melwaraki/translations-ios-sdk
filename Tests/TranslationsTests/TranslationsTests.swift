import XCTest
@testable import Translations

final class TranslationsTests: XCTestCase {
    func testConfigurationDefaults() {
        let cfg = TranslationsConfiguration(
            baseURL: URL(string: "https://example.com/api")!,
            projectId: "p1",
            token: "tsk_test"
        )
        XCTAssertEqual(cfg.matchThreshold, 0.4, accuracy: 0.0001)
        XCTAssertFalse(cfg.enabledInRelease)
        XCTAssertNil(cfg.defaultLocale)
        XCTAssertTrue(cfg.useOfflineCache)
        XCTAssertEqual(cfg.cacheRefreshPolicy, .oncePerLaunch)
    }

    func testConfigureSetsClient() {
        Translations.configure(
            baseURL: URL(string: "https://example.com/api")!,
            projectId: "p1",
            token: "tsk_test"
        )
        // Cannot inspect private state; just assert it doesn't crash and isEnabled
        // resolves. In DEBUG builds isEnabled is true once configured.
        XCTAssertTrue(Translations.isEnabled)
    }

    func testRefreshPolicyIntervalEquatable() {
        XCTAssertEqual(CacheRefreshPolicy.every(60), CacheRefreshPolicy.every(60))
        XCTAssertNotEqual(CacheRefreshPolicy.every(60), CacheRefreshPolicy.every(120))
        XCTAssertNotEqual(CacheRefreshPolicy.always, CacheRefreshPolicy.manual)
    }
}

// MARK: - Cache tests

final class XcstringsCacheTests: XCTestCase {
    private func makeCache(projectId: String = UUID().uuidString) -> (XcstringsCache, MockURLProtocol.Type) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let cfg = TranslationsConfiguration(
            baseURL: URL(string: "https://example.com/api/")!,
            projectId: projectId,
            token: "tsk_test"
        )
        let client = APIClient(configuration: cfg, session: session)
        return (XcstringsCache(projectId: projectId, client: client), MockURLProtocol.self)
    }

    private static let sampleDoc = """
    {
      "sourceLanguage": "en",
      "version": "1.0",
      "strings": {
        "hello.world": {
          "comment": "Greeting",
          "extractionState": "manual",
          "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "Hello, world" } },
            "fr": { "stringUnit": { "state": "translated", "value": "Bonjour, le monde" } }
          }
        },
        "buy.button": {
          "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "Buy now" } },
            "fr": { "stringUnit": { "state": "translated", "value": "Acheter" } }
          }
        }
      }
    }
    """.data(using: .utf8)!

    func testRefreshDownloadsAndCachesDocument() async throws {
        let (cache, mock) = makeCache()
        mock.handler = { _ in
            return (HTTPURLResponse(
                url: URL(string: "https://example.com/")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"v1\""]
            )!, Self.sampleDoc)
        }

        try await cache.refresh()
        let has = await cache.hasDocument
        XCTAssertTrue(has)
        let etag = await cache.currentEtag
        XCTAssertEqual(etag, "\"v1\"")

        let matches = await cache.match(strings: ["Hello, world", "missing"], locale: "fr", threshold: 0.4)
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].matched)
        XCTAssertEqual(matches[0].key, "hello.world")
        XCTAssertEqual(matches[0].translation, "Bonjour, le monde")
        XCTAssertFalse(matches[1].matched)

        let lookup = await cache.lookup(key: "buy.button", locale: "fr")
        XCTAssertEqual(lookup?.translations.first?.value, "Acheter")

        let locales = await cache.availableLocales()
        XCTAssertEqual(locales, ["fr"])
    }

    func testRefreshSendsIfNoneMatchAndHandles304() async throws {
        let (cache, mock) = makeCache()
        var requestCount = 0
        var lastIfNoneMatch: String? = nil
        mock.handler = { req in
            requestCount += 1
            lastIfNoneMatch = req.value(forHTTPHeaderField: "If-None-Match")
            if requestCount == 1 {
                return (HTTPURLResponse(
                    url: req.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["ETag": "\"abc\""]
                )!, Self.sampleDoc)
            }
            return (HTTPURLResponse(
                url: req.url!, statusCode: 304, httpVersion: nil, headerFields: nil
            )!, Data())
        }

        try await cache.refresh()
        XCTAssertNil(lastIfNoneMatch)

        try await cache.refresh()
        XCTAssertEqual(lastIfNoneMatch, "\"abc\"")
        let etag = await cache.currentEtag
        XCTAssertEqual(etag, "\"abc\"")
        let stillHas = await cache.hasDocument
        XCTAssertTrue(stillHas)
    }

    func testCachePersistsAcrossInstances() async throws {
        let projectId = "persist-\(UUID().uuidString)"
        let (cache1, mock) = makeCache(projectId: projectId)
        mock.handler = { _ in
            return (HTTPURLResponse(
                url: URL(string: "https://example.com/")!, statusCode: 200, httpVersion: nil,
                headerFields: ["ETag": "\"x\""]
            )!, Self.sampleDoc)
        }
        try await cache1.refresh()

        // A fresh cache for the same project should pick up the persisted
        // file without performing any network request — this is the
        // offline-first path used by `Translations.activate()`.
        let (cache2, mock2) = makeCache(projectId: projectId)
        var requestCount = 0
        mock2.handler = { _ in
            requestCount += 1
            return (HTTPURLResponse(
                url: URL(string: "https://example.com/")!, statusCode: 500, httpVersion: nil,
                headerFields: nil
            )!, Data())
        }
        await cache2.loadFromDiskIfNeeded()
        let has = await cache2.hasDocument
        XCTAssertTrue(has)
        let etag = await cache2.currentEtag
        XCTAssertEqual(etag, "\"x\"")
        // Match + lookup must never hit the network when a cached doc exists.
        let matches = await cache2.match(
            strings: ["Hello, world"], locale: "fr", threshold: 0.4
        )
        XCTAssertTrue(matches[0].matched)
        XCTAssertNotNil(await cache2.lookup(key: "buy.button", locale: "fr"))
        XCTAssertEqual(requestCount, 0, "Cached match/lookup must not hit the network")
    }

    func testMatchAndLookupAreOfflineWhenCachedDocumentExists() async throws {
        // Even if every subsequent network call would fail, a cache that has
        // already loaded a document must continue to serve match + lookup.
        let (cache, mock) = makeCache()
        mock.handler = { _ in
            return (HTTPURLResponse(
                url: URL(string: "https://example.com/")!,
                statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
            )!, Self.sampleDoc)
        }
        try await cache.refresh()

        // Simulate going offline: any further request throws.
        mock.handler = { _ in
            return (HTTPURLResponse(
                url: URL(string: "https://example.com/")!,
                statusCode: 503, httpVersion: nil, headerFields: nil
            )!, Data())
        }
        let matches = await cache.match(
            strings: ["Hello, world", "Buy now"], locale: "fr", threshold: 0.4
        )
        XCTAssertTrue(matches.allSatisfy { $0.matched })
        XCTAssertEqual(matches[0].translation, "Bonjour, le monde")
        XCTAssertEqual(matches[1].translation, "Acheter")
    }
}

// MARK: - URLProtocol stub

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "test", code: -1))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
