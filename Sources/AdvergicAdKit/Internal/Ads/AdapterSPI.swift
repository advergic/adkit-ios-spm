import Foundation
#if canImport(UIKit)
import UIKit
#endif

// The contract between the core and the per-network modules (`AdvergicAdKitAdMob`, …).
//
// Public only under `@_spi(AdvergicAdapters)`: an app importing `AdvergicAdKit` does not see any
// of this, while an adapter module opts in with `@_spi(AdvergicAdapters) import AdvergicAdKit`.
//
// Adapters are found by class name rather than registered: adding the network's package is the
// whole integration, the way a network on the Android classpath is. See `AdapterDiscovery`.

// MARK: Initializer

/// Starts one network's ad stack.
@_spi(AdvergicAdapters)
public protocol AdvergicAdsInitializer: AnyObject {
    var isReady: Bool { get }

    /// Idempotent — safe to call from every slot as well as from `Advergic.initialize`.
    func initialize()

    /// Resolves on the main thread once the stack's fate is known. Callers arriving after
    /// resolution are answered immediately.
    func awaitReady(onReady: @escaping () -> Void, onUnavailable: @escaping (String) -> Void)
}

/// Shared plumbing for network initializers: run once on the main thread, answer every waiter
/// whether the outcome arrives before or after they ask.
///
/// Subclasses override `start()` and end it with `markReady()` or `markUnavailable(_:)`.
///
/// Inherits `NSObject` so a subclass can act as an Objective-C delegate. Several networks
/// hand back their initialization result through one — Unity Ads' `UnityAdsInitializationDelegate`
/// is the first — and those protocols inherit `NSObjectProtocol`, which Swift will not synthesise
/// on a class that is not an `NSObject`.
@_spi(AdvergicAdapters)
open class AdvergicBaseInitializer: NSObject, AdvergicAdsInitializer {

    private struct Waiter {
        let onReady: () -> Void
        let onUnavailable: (String) -> Void
    }

    public let networkName: String

    // Main-thread only.
    private var waiters: [Waiter] = []
    private var started = false
    private var unavailableReason: String?
    public private(set) var isReady = false

    public init(networkName: String) {
        self.networkName = networkName
        super.init()
    }

    public final func initialize() {
        MainThread.post { [self] in
            guard !started else { return }
            started = true
            AdvergicLog.d("Initializing \(networkName)")
            start()
        }
    }

    public final func awaitReady(onReady: @escaping () -> Void, onUnavailable: @escaping (String) -> Void) {
        MainThread.post { [self] in
            if isReady {
                onReady()
            } else if let reason = unavailableReason {
                onUnavailable(reason)
            } else {
                waiters.append(Waiter(onReady: onReady, onUnavailable: onUnavailable))
            }
        }
    }

    /// Called once, on the main thread. Must end in `markReady()` or `markUnavailable(_:)`.
    open func start() {
        markUnavailable("\(networkName) initializer does not implement start()")
    }

    /// Safe from any thread; waiters are answered on the main thread.
    public final func markReady() {
        MainThread.post { [self] in
            guard !isReady, unavailableReason == nil else { return }
            isReady = true
            AdvergicLog.d("\(networkName) ready")
            drain().forEach { $0.onReady() }
        }
    }

    public final func markUnavailable(_ reason: String) {
        MainThread.post { [self] in
            guard !isReady, unavailableReason == nil else { return }
            unavailableReason = reason
            AdvergicLog.e("\(networkName) unavailable: \(reason)")
            drain().forEach { $0.onUnavailable(reason) }
        }
    }

    /// True when a credential is still the shipped placeholder. Every network but AdMob and
    /// Yandex needs real credentials from its own dashboard.
    public final func isPlaceholder(_ credential: String) -> Bool {
        credential.trimmingCharacters(in: .whitespaces).isEmpty || credential.hasPrefix("REPLACE_WITH")
    }

    public final func missingCredential(_ what: String) -> String {
        "\(networkName) \(what) is not set — no ads will load. Set it in the dashboard or AdvergicConfig."
    }

    private func drain() -> [Waiter] {
        let queued = waiters
        waiters.removeAll()
        return queued
    }
}

// MARK: Setup handed to a network module

/// What a network module needs to start: the server's credentials for it, and the local config
/// they fall back to.
@_spi(AdvergicAdapters)
public struct AdvergicNetworkSetup {
    public let network: AdvergicAdNetwork
    public let config: AdvergicConfig
    let platform: RemotePlatform?

    init(network: AdvergicAdNetwork, config: AdvergicConfig, platform: RemotePlatform?) {
        self.network = network
        self.config = config
        self.platform = platform
    }

    /// The server's value, falling back to the local one — server-first so a rotated key takes
    /// effect without an app release. Keys follow the dashboard catalog: `app_id`, `account_id`,
    /// `sdk_key`, `game_id`, `app_key`, `source_id`.
    public func credential(_ key: String, fallback: String) -> String {
        platform?.credential(key) ?? fallback
    }

    public func testMode(fallback: Bool) -> Bool {
        platform?.testMode ?? fallback
    }

    public func testDevices(fallback: [String]) -> [String] {
        let fromServer = platform?.testDevices ?? []
        return fromServer.isEmpty ? fallback : fromServer
    }

    public var enableLogging: Bool { config.enableLogging }
}

// MARK: Slot adapters

#if canImport(UIKit)

/// What an in-layout slot reports back, whichever network filled it.
@_spi(AdvergicAdapters)
public struct AdvergicBannerCallbacks {
    public let onLoaded: () -> Void
    public let onFailed: (String) -> Void
    public let onClicked: () -> Void
    public let onRevenue: (AdvergicAdRevenue) -> Void
    /// The ad served, but the network disclosed no price and never will for this fill.
    public let onRevenueUnavailable: (String) -> Void

    public init(
        onLoaded: @escaping () -> Void,
        onFailed: @escaping (String) -> Void,
        onClicked: @escaping () -> Void,
        onRevenue: @escaping (AdvergicAdRevenue) -> Void,
        onRevenueUnavailable: @escaping (String) -> Void
    ) {
        self.onLoaded = onLoaded
        self.onFailed = onFailed
        self.onClicked = onClicked
        self.onRevenue = onRevenue
        self.onRevenueUnavailable = onRevenueUnavailable
    }
}

/// What a fullscreen slot reports back.
@_spi(AdvergicAdapters)
public struct AdvergicFullscreenCallbacks {
    /// Cached; `show(from:)` will display it.
    public let onLoaded: () -> Void
    public let onFailed: (String) -> Void
    public let onShown: () -> Void
    /// Dismissed — the ad is spent.
    public let onDismissed: () -> Void
    public let onClicked: () -> Void
    public let onRewardEarned: (Int, String) -> Void
    public let onRevenue: (AdvergicAdRevenue) -> Void
    public let onRevenueUnavailable: (String) -> Void

    public init(
        onLoaded: @escaping () -> Void,
        onFailed: @escaping (String) -> Void,
        onShown: @escaping () -> Void,
        onDismissed: @escaping () -> Void,
        onClicked: @escaping () -> Void,
        onRewardEarned: @escaping (Int, String) -> Void,
        onRevenue: @escaping (AdvergicAdRevenue) -> Void,
        onRevenueUnavailable: @escaping (String) -> Void
    ) {
        self.onLoaded = onLoaded
        self.onFailed = onFailed
        self.onShown = onShown
        self.onDismissed = onDismissed
        self.onClicked = onClicked
        self.onRewardEarned = onRewardEarned
        self.onRevenue = onRevenue
        self.onRevenueUnavailable = onRevenueUnavailable
    }
}

/// One slot's worth of a network's banner. `attach` adds the network's view to `container` and
/// requests a fill at `size`. Called on the main thread.
@_spi(AdvergicAdapters)
public protocol AdvergicBannerAdapter: AnyObject {
    func attach(
        container: UIView,
        adUnitId: String,
        size: AdvergicAdSize,
        bid: AdvergicResolvedBid?,
        callbacks: AdvergicBannerCallbacks
    )
    func destroy()
}

/// Two-phase: `load` caches an ad, `show(from:)` displays it later over a view controller.
@_spi(AdvergicAdapters)
public protocol AdvergicFullscreenAdapter: AnyObject {
    func load(
        adUnitId: String,
        format: AdvergicAdFormat,
        bid: AdvergicResolvedBid?,
        callbacks: AdvergicFullscreenCallbacks
    )
    /// No-op unless a load has reported `onLoaded`.
    func show(from viewController: UIViewController)
    func destroy()
}

/// The network hands over assets and the adapter binds them into a view it builds, so there is
/// no size: the slot's height follows the content.
@_spi(AdvergicAdapters)
public protocol AdvergicNativeAdapter: AnyObject {
    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks)
    func destroy()
}

#endif

/// A bid that cleared before the ad was fetched, handed to the adapter that must load with it.
@_spi(AdvergicAdapters)
public struct AdvergicResolvedBid {
    public let payload: String
    public let price: Double
    public let currency: String

    public init(payload: String, price: Double, currency: String) {
        self.payload = payload
        self.price = price
        self.currency = currency
    }
}

// MARK: The per-network entry point

/// Implemented once per network module, as an `NSObject` subclass exported under the Objective-C
/// name `AdapterDiscovery` looks for (e.g. `@objc(AdvergicAdMobAdapter)`).
@_spi(AdvergicAdapters)
public protocol AdvergicNetworkAdapter: NSObject {
    static var network: AdvergicAdNetwork { get }

    init()

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer

    #if canImport(UIKit)
    func makeBannerAdapter() -> AdvergicBannerAdapter
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter
    func makeNativeAdapter() -> AdvergicNativeAdapter

    /// The network's on-device debugging tool, if it ships one. Return false when it has none.
    func showDebugPanel(from viewController: UIViewController) -> Bool
    #endif

    /// A pre-load bidder token, for networks that can take part in an auction. Nil otherwise.
    func bidderToken() async -> String?
}

@_spi(AdvergicAdapters)
public extension AdvergicNetworkAdapter {
    #if canImport(UIKit)
    func showDebugPanel(from viewController: UIViewController) -> Bool { false }
    #endif
    func bidderToken() async -> String? { nil }
}

// MARK: Logging for adapter modules

/// The core's gated console log, for adapter modules — so `enableLogging` silences them too.
@_spi(AdvergicAdapters)
public enum AdvergicAdapterLog {
    public static func d(_ message: @autoclosure () -> String) { AdvergicLog.d(message()) }
    public static func i(_ message: @autoclosure () -> String) { AdvergicLog.i(message()) }
    public static func w(_ message: @autoclosure () -> String) { AdvergicLog.w(message()) }
    public static func e(_ message: @autoclosure () -> String) { AdvergicLog.e(message()) }
    public static var isEnabled: Bool { AdvergicLog.enabled }
}
