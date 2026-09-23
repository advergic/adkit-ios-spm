import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Entry point of the Advergic SDK.
///
/// Call `initialize` once, as early as possible — `application(_:didFinishLaunchingWithOptions:)`
/// or your SwiftUI `App.init`. It validates the API key, then fetches this app's mediation config
/// with a signed request.
///
/// ```swift
/// Advergic.initialize(apiKey: "adv_live_xxxxxxxx")
/// ```
///
/// Thread-safe. Repeat calls after a success are no-ops that report the config already held.
public enum Advergic {

    private static let core = Locked<Core?>(nil)

    /// Overrides `Bundle.main.bundleIdentifier`. Tests only — the bundle id is detected rather
    /// than configured precisely so it cannot be spoofed.
    static var bundleIdOverride: String?
    /// Test seams.
    static var httpClientOverride: HTTPClient?
    static var cacheOverride: ConfigCache?

    /// True once a config — live or cached — is in force.
    public static var isInitialized: Bool { core.get()?.remoteConfig != nil }

    /// The config in force, or nil before a successful `initialize`.
    public static var remoteConfig: AdvergicRemoteConfig? { core.get()?.remoteConfig }

    /// Networks this app's config enables, in the order the server listed them. Only these are
    /// ever started. Empty until the config lands.
    public static var enabledNetworks: [AdvergicAdNetwork] { AdsRegistry.enabledNetworks }

    /// The SDK version, as reported to Advergic's collectors.
    public static var sdkVersion: String { Constants.sdkVersion }

    /// Declares that the SDK is driven by a wrapper (Unity, Flutter) rather than called directly.
    /// Call before `initialize`.
    ///
    /// - Parameters:
    ///   - name: Wrapper identity, e.g. `"unity"`.
    ///   - version: The wrapper package's own version, not the SDK's.
    public static func setIntegration(name: String, version: String? = nil) {
        Integration.set(name: name, version: version)
    }

    /// Initializes the SDK without blocking. `completion`, if given, runs on the main thread.
    public static func initialize(
        apiKey: String,
        config: AdvergicConfig = AdvergicConfig(),
        completion: ((Result<AdvergicRemoteConfig, AdvergicError>) -> Void)? = nil
    ) {
        switch prepare(apiKey: apiKey, config: config) {
        case .failure(let error):
            if let completion { MainThread.post { completion(.failure(error)) } }
        case .success(let active):
            Task {
                let result = await active.initialize()
                if let completion { MainThread.post { completion(result) } }
            }
        }
    }

    /// `async` form of `initialize`. Expected failures come back as `.failure`, never thrown.
    @discardableResult
    public static func initialize(
        apiKey: String,
        config: AdvergicConfig = AdvergicConfig()
    ) async -> Result<AdvergicRemoteConfig, AdvergicError> {
        switch prepare(apiKey: apiKey, config: config) {
        case .failure(let error): return .failure(error)
        case .success(let active): return await active.initialize()
        }
    }

    #if canImport(UIKit)
    /// Opens the network's own on-device debugging tool, when it ships one (Yandex, AppLovin
    /// MAX). No-op with a log otherwise, or when that network has not initialized.
    public static func showDebugPanel(for network: AdvergicAdNetwork, from viewController: UIViewController) {
        guard AdsRegistry.provider?.initializer(network).isReady == true else {
            AdvergicLog.w("\(network) is not initialized — debug panel not shown")
            return
        }
        let shown = AdapterDiscovery.adapter(for: network)?.showDebugPanel(from: viewController) ?? false
        if !shown {
            AdvergicLog.w("\(network) has no debug panel — see the console for its diagnostics")
        }
    }
    #endif

    /// This device's Meta bidder token, for your bid backend. Short-lived: fetch per request.
    /// Nil when the Meta module isn't installed.
    public static func metaBidderToken() async -> String? {
        await AdapterDiscovery.adapter(for: .meta)?.bidderToken()
    }

    /// Routes Meta bid requests through your backend, so Meta slots run an auction before
    /// fetching and report what the impression actually paid. Register before the first Meta
    /// slot loads; pass nil to turn bidding off.
    public static func setMetaBidProvider(_ provider: AdvergicMetaBidProvider?) {
        MetaBidRegistry.provider = provider
        AdvergicLog.d(provider == nil
            ? "Meta bidding disabled — slots will fetch ads without an auction"
            : "Meta bidding enabled via \(type(of: provider!))")
    }

    /// Drops the config, stops diagnostics and forgets learned state. Mostly for tests and
    /// sign-out; a later `initialize` starts from scratch.
    public static func shutdown() {
        core.set(nil)
        AdsRegistry.reset()
        MetaBidRegistry.reset()
        Telemetry.stop()
        Analytics.stop()
        AdvergicLog.d("SDK shut down")
    }

    private static func prepare(apiKey: String, config: AdvergicConfig) -> Result<Core, AdvergicError> {
        AdvergicLog.enabled = config.enableLogging

        if let error = Core.validateApiKey(apiKey) {
            AdvergicLog.e("Refusing to initialize: \(error.message)")
            return .failure(error)
        }

        guard let bundleId = bundleIdOverride ?? Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
            let error = AdvergicError.invalidConfiguration("The app has no bundle identifier to sign the request with")
            AdvergicLog.e("Refusing to initialize: \(error.message)")
            return .failure(error)
        }

        return .success(core.mutate { current in
            if let existing = current { return existing }
            let created = Core.create(
                apiKey: apiKey,
                bundleId: bundleId,
                config: config,
                httpClient: httpClientOverride,
                cache: cacheOverride
            )
            current = created
            return created
        })
    }
}
