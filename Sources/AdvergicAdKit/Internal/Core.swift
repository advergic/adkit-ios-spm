import Foundation

/// Everything the public `Advergic` facade delegates to. One instance per `initialize`.
///
/// Serializes concurrent init attempts so the config endpoint is hit once.
actor Core {

    typealias InitResult = Result<AdvergicRemoteConfig, AdvergicError>

    let config: AdvergicConfig
    private let apiKey: String
    private let bundleId: String
    private let client: MiddlewareClient
    private let cache: ConfigCache
    /// Brings the ad stack up against a config, returning the initializer for the network
    /// unnamed slots use. A function because which network that is depends on the config.
    private let adsStack: (AdvergicRemoteConfig) -> AdvergicAdsInitializer?

    private let applied = Locked<AdvergicRemoteConfig?>(nil)
    private var inFlight: Task<InitResult, Never>?

    init(
        apiKey: String,
        bundleId: String,
        config: AdvergicConfig,
        client: MiddlewareClient,
        cache: ConfigCache,
        adsStack: @escaping (AdvergicRemoteConfig) -> AdvergicAdsInitializer?
    ) {
        self.apiKey = apiKey
        self.bundleId = bundleId
        self.config = config
        self.client = client
        self.cache = cache
        self.adsStack = adsStack
    }

    /// The config in force — live, or cached while the live one is in flight.
    nonisolated var remoteConfig: AdvergicRemoteConfig? { applied.get() }

    /// Idempotent: after a success, returns the config already held.
    func initialize() async -> InitResult {
        if let current = applied.get() {
            AdvergicLog.d("Already initialized, reusing cached config")
            return .success(current)
        }
        if let running = inFlight {
            return await running.value
        }
        let task = Task { await self.run() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// The fetch always runs. What varies is how long ads wait for it: past `configTimeout` a
    /// recent cached config is applied so slots can start, and the live response replaces it when
    /// it lands. With nothing cached, slots keep waiting — better a late ad than a request against
    /// ad units that may no longer exist.
    private func run() async -> InitResult {
        let fetch = Task { [client, apiKey, bundleId] in
            await client.fetchConfig(apiKey: apiKey, bundleId: bundleId)
        }

        var outcome = await withTimeout(config.configTimeout) { await fetch.value }
        if outcome == nil {
            if let cached = cache.load() {
                AdvergicLog.w(
                    "Config fetch exceeded \(millis(config.configTimeout))ms — starting ads on " +
                        "the cached config; the live one will apply when it arrives"
                )
                Telemetry.warn(
                    "Config Timeout",
                    "Config fetch exceeded \(millis(config.configTimeout))ms — started on the cached config",
                    attrs: ["config.timeout.ms": .string(String(millis(config.configTimeout)))]
                )
                apply(cached)
            }
            // Awaited regardless: the fetch is still the authority, and it decides whether an
            // uncached app gets ads at all.
            outcome = await fetch.value
        }
        let result = outcome!

        switch result {
        case .success(let live):
            cache.save(live)
            if applied.get() == nil {
                apply(live)
            } else {
                // The cache already opened the gate. Refresh what the next launch reads, but leave
                // running networks alone — re-gating mid-session would tear down slots on screen.
                AdvergicLog.d("Live config received; cached copy refreshed for next launch")
                applied.set(live)
            }

        case .failure(let error):
            AdvergicLog.w("Initialization failed: \(error)")
            var attrs: Attributes = ["config.rejected": .string(String(error.isRejection))]
            if case .http(let status, _) = error { attrs["http.status"] = .string(String(status)) }
            Telemetry.error("Config Fail", "Config fetch failed", error: error.message, attrs: attrs)

            if error.isRejection {
                // The server refused this app. Serving from a config it would no longer issue is
                // exactly what the publisher check exists to stop.
                cache.clear()
                failIfNothingApplied(error)
            } else if applied.get() == nil {
                // 5xx, timeout, no connectivity: the middleware is unreachable, not that this app
                // is unwelcome. Not limited to the timeout path — a 502 fails *fast*.
                if let cached = cache.load() {
                    AdvergicLog.w("Config unavailable (\(error.message)) — starting ads on the cached config")
                    Telemetry.warn(
                        "Config Cache Fallback",
                        "Config unavailable — started ads on the cached config",
                        error: error.message
                    )
                    apply(cached)
                } else {
                    failIfNothingApplied(error)
                }
            }
        }

        return result
    }

    /// Only report a failure when nothing — live or cached — could be applied.
    private func failIfNothingApplied(_ error: AdvergicError) {
        guard applied.get() == nil else { return }
        AdvergicLog.w("No config could be applied — ads will not load")
        Telemetry.error("SDK Init Aborted", "No config could be applied — ads will not load", error: error.message)
        AdsRegistry.markConfigFailed("No ad config for this app: \(error.message)")
    }

    private func apply(_ remote: AdvergicRemoteConfig) {
        applied.set(remote)
        AdvergicLog.d("Initialized with config \(remote)")
        // Order matters: the config decides which networks may start, so the gates go in before
        // markConfigReady releases the slots waiting to ask.
        let initializer = adsStack(remote)
        AdsRegistry.markConfigReady()
        initializer?.initialize()
    }

    private func millis(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    // MARK: Factory

    /// Cheap client-side checks so obvious mistakes don't cost a round trip.
    static func validateApiKey(_ apiKey: String) -> AdvergicError? {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalidApiKey("API key must not be blank")
        }
        if apiKey.count < minApiKeyLength {
            return .invalidApiKey("API key is too short to be valid")
        }
        if apiKey.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) {
            return .invalidApiKey("API key must not contain whitespace")
        }
        return nil
    }

    static let minApiKeyLength = 8

    static func create(
        apiKey: String,
        bundleId: String,
        config: AdvergicConfig,
        httpClient: HTTPClient? = nil,
        cache: ConfigCache? = nil
    ) -> Core {
        // Before anything that can fail, so the first failure is already reportable. The bundle
        // id is what identifies a publisher in the collector.
        Telemetry.start(serviceName: bundleId)
        Analytics.start(bundleId: bundleId, sessionId: Telemetry.sessionId)
        Analytics.track("session.start")
        Telemetry.info(
            "SDK Init",
            "Advergic AdKit \(Constants.sdkVersion) initializing",
            attrs: [
                "sdk.version": .string(Constants.sdkVersion),
                "config.require_for_ads": .string(String(config.requireConfigForAds)),
            ]
        )

        let provider = AdsProvider(config: config)
        AdsRegistry.provider = provider
        AdsRegistry.defaultNetwork = config.adNetwork
        if !config.requireConfigForAds {
            // Opted out of the publisher check: slots may load before or without a config.
            AdsRegistry.markConfigReady()
        }

        return Core(
            apiKey: apiKey,
            bundleId: bundleId,
            config: config,
            client: MiddlewareClient(
                baseURL: config.baseURL,
                httpClient: httpClient ?? URLSessionHTTPClient(
                    connectTimeout: config.connectTimeout, readTimeout: config.readTimeout
                )
            ),
            cache: cache ?? UserDefaultsConfigCache(),
            adsStack: { remote in
                // Attribution starts alongside the ad stack: a reporter started after the first
                // impression has already missed it.
                let mmp = MmpFactory.create(RemoteMmp.parseAll(remote.json))
                AdsRegistry.mmp = mmp
                MainThread.post { mmp.start() }

                let ads = RemoteAdsConfig.parse(remote.json)
                provider.applyRemoteConfig(ads)
                AdsRegistry.enabledNetworks = ads.enabledNetworks
                AdsRegistry.defaultNetwork = ads.defaultNetwork(preferred: config.adNetwork)
                return provider.initializer(AdsRegistry.defaultNetwork)
            }
        )
    }
}
