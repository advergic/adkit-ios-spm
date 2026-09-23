import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

@MainActor
final class CoreTests: XCTestCase {

    private let validBody = #"{"connectedNetworks":{"admob":{}},"mediation":{"placements":[]}}"#
    private let cachedBody = #"{"cached":true}"#
    private var stackStarts = 0

    override func setUp() {
        super.setUp()
        AdsRegistry.reset()
        stackStarts = 0
    }

    private func makeCore(_ http: FakeHTTPClient, cache: ConfigCache = MemoryConfigCache(), timeout: TimeInterval = 2.5) -> Core {
        Core(
            apiKey: "adv_test_key",
            bundleId: "com.example.app",
            config: AdvergicConfig(configTimeout: timeout),
            client: MiddlewareClient(baseURL: "https://example.test", httpClient: http),
            cache: cache,
            adsStack: { [weak self] _ in
                self?.stackStarts += 1
                return nil
            }
        )
    }

    /// Lets `MainThread.post` blocks queued from the actor run.
    private func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testStartsTheAdStackAfterASuccessfulConfigFetch() async {
        let core = makeCore(FakeHTTPClient(body: validBody))
        let result = await core.initialize()
        XCTAssertNotNil(try? result.get())
        XCTAssertEqual(stackStarts, 1)
        await settle()
        XCTAssertTrue(AdsRegistry.isConfigReady)
    }

    func testDoesNotStartTheAdStackWhenTheConfigFetchFails() async {
        let core = makeCore(FakeHTTPClient(status: 500, body: nil))
        guard case .failure = await core.initialize() else { return XCTFail() }
        XCTAssertEqual(stackStarts, 0)
        XCTAssertNil(core.remoteConfig)
    }

    func testCachesTheConfigAndHitsTheEndpointOnce() async {
        let http = FakeHTTPClient(body: validBody)
        let core = makeCore(http)
        _ = await core.initialize()
        _ = await core.initialize()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(stackStarts, 1)
    }

    func testConcurrentInitializeCallsShareOneRequest() async {
        let http = FakeHTTPClient(body: validBody)
        http.delay = 0.2
        let core = makeCore(http)
        async let first = core.initialize()
        async let second = core.initialize()
        _ = await (first, second)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testExposesTheConfigOnlyAfterSuccess() async {
        let core = makeCore(FakeHTTPClient(body: validBody))
        XCTAssertNil(core.remoteConfig)
        _ = await core.initialize()
        XCTAssertEqual(core.remoteConfig?.raw, validBody)
    }

    func testARejectedAppClearsTheCacheSoItCannotKeepServing() async {
        let cache = MemoryConfigCache(cachedBody)
        let core = makeCore(FakeHTTPClient(status: 403, body: nil), cache: cache)
        _ = await core.initialize()
        XCTAssertEqual(cache.cleared, 1)
        XCTAssertNil(cache.stored)
        XCTAssertEqual(stackStarts, 0)
    }

    func testARejectionFailsEveryWaitingSlotWithTheReason() async {
        var failure: String?
        AdsRegistry.whenConfigReady(onFailed: { failure = $0 }) { XCTFail("gate must not open") }
        _ = await makeCore(FakeHTTPClient(status: 401, body: nil)).initialize()
        await settle()
        XCTAssertTrue(failure?.hasPrefix("No ad config for this app: Config request failed with HTTP 401") ?? false, failure ?? "nil")
    }

    func testANetworkFailureLeavesTheCacheIntact() async {
        let http = FakeHTTPClient()
        http.error = HTTPClientError.transport("offline")
        let cache = MemoryConfigCache(cachedBody)
        _ = await makeCore(http, cache: cache).initialize()
        XCTAssertEqual(cache.cleared, 0)
        XCTAssertNotNil(cache.stored)
    }

    func testA502StartsAdsFromTheCache() async {
        let core = makeCore(FakeHTTPClient(status: 502, body: nil), cache: MemoryConfigCache(cachedBody))
        guard case .failure = await core.initialize() else { return XCTFail("the live failure is still reported") }
        XCTAssertEqual(stackStarts, 1)
        XCTAssertEqual(core.remoteConfig?.raw, cachedBody)
        await settle()
        XCTAssertTrue(AdsRegistry.isConfigReady)
    }

    func testANetworkFailureWithNoCacheStartsNothing() async {
        let http = FakeHTTPClient()
        http.error = HTTPClientError.transport("offline")
        var failure: String?
        AdsRegistry.whenConfigReady(onFailed: { failure = $0 }) {}
        _ = await makeCore(http).initialize()
        await settle()
        XCTAssertEqual(stackStarts, 0)
        XCTAssertNotNil(failure)
    }

    func testASuccessfulFetchIsWrittenToTheCache() async {
        let cache = MemoryConfigCache()
        _ = await makeCore(FakeHTTPClient(body: validBody), cache: cache).initialize()
        XCTAssertEqual(cache.saved, 1)
        XCTAssertEqual(cache.stored?.raw, validBody)
    }

    func testASlowFetchStartsOnTheCacheThenRefreshesItWithoutRestarting() async {
        let http = FakeHTTPClient(body: validBody)
        http.delay = 0.4
        let cache = MemoryConfigCache(cachedBody)
        let core = makeCore(http, cache: cache, timeout: 0.1)

        let result = await core.initialize()
        XCTAssertEqual(try? result.get().raw, validBody)
        // Started once, on the cache; the live config replaced what's held but did not re-gate.
        XCTAssertEqual(stackStarts, 1)
        XCTAssertEqual(core.remoteConfig?.raw, validBody)
        XCTAssertEqual(cache.stored?.raw, validBody)
    }

    func testASlowFetchWithNoCacheWaitsForTheLiveResponse() async {
        let http = FakeHTTPClient(body: validBody)
        http.delay = 0.3
        let core = makeCore(http, timeout: 0.05)
        _ = await core.initialize()
        XCTAssertEqual(stackStarts, 1)
        XCTAssertEqual(core.remoteConfig?.raw, validBody)
    }

    func testCacheExpiresAfter24Hours() {
        let defaults = UserDefaults(suiteName: "advergic.tests.\(UUID().uuidString)")!
        var now = Date(timeIntervalSince1970: 1_000_000)
        let cache = UserDefaultsConfigCache(defaults: defaults, clock: Clock { now })
        cache.save(AdvergicRemoteConfig.parse(validBody)!)
        now += 23 * 3600
        XCTAssertNotNil(cache.load())
        now += 2 * 3600
        XCTAssertNil(cache.load())
        cache.clear()
        XCTAssertNil(defaults.string(forKey: "body"))
    }
}
