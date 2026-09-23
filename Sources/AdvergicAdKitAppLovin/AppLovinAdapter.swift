#if canImport(UIKit) && canImport(AppLovinSDK)
import AppLovinSDK
import Foundation
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// AppLovin MAX. A mediator: it prices whatever demand wins, and the price arrives per ad on the
/// revenue delegate, always in USD. MAX fixes the format when a unit is created, so each size and
/// format needs its own unit.
@objc(AdvergicAppLovinAdapter)
final class AppLovinAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .appLovin

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        AppLovinInitializer(
            sdkKey: setup.credential("sdk_key", fallback: setup.config.applovinSdkKey),
            verboseLogging: setup.enableLogging,
            testDevices: setup.testDevices(fallback: setup.config.testDeviceAdvertisingIds)
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { AppLovinBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { AppLovinFullscreenAdapter() }

    /// MAX's native renderer binds through a view template it owns; not wired, as on Android.
    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .appLovin, reason: .notIntegrated)
    }

    /// MAX's mediation debugger: adapter versions, per-network init state, live waterfall.
    func showDebugPanel(from viewController: UIViewController) -> Bool {
        ALSdk.shared().showMediationDebugger()
        return true
    }
}

enum AppLovinSupport {

    static func message(_ error: MAError) -> String {
        var text = "\(error.message) (code=\(error.code.rawValue))"
        if error.mediatedNetworkErrorCode != 0 {
            text += ", network: \(error.mediatedNetworkErrorMessage) (\(error.mediatedNetworkErrorCode))"
        }
        return text
    }

    static func isPlaceholder(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespaces).isEmpty || id.hasPrefix("REPLACE_WITH")
    }

    /// MAX always reports USD. A zero is MAX declining to disclose, not the impression paying 0.
    static func report(_ ad: MAAd, onRevenue: (AdvergicAdRevenue) -> Void, onUnavailable: (String) -> Void) {
        guard ad.revenue > 0 else {
            onUnavailable("AppLovin disclosed no revenue for this fill (\(ad.networkName))")
            return
        }
        onRevenue(AdvergicAdRevenue(
            amount: ad.revenue,
            currencyCode: "USD",
            amountUsd: ad.revenue,
            precision: ad.revenuePrecision.isEmpty ? "mediation" : ad.revenuePrecision,
            network: ad.networkName.isEmpty ? "applovin" : ad.networkName,
            adUnitId: ad.adUnitIdentifier
        ))
    }
}

final class AppLovinInitializer: AdvergicBaseInitializer {

    private let sdkKey: String
    private let verboseLogging: Bool
    private let testDevices: [String]

    init(sdkKey: String, verboseLogging: Bool, testDevices: [String]) {
        self.sdkKey = sdkKey
        self.verboseLogging = verboseLogging
        self.testDevices = testDevices
        super.init(networkName: AdvergicAdNetwork.appLovin.name)
    }

    override func start() {
        if isPlaceholder(sdkKey) {
            markUnavailable(missingCredential("SDK key"))
            return
        }
        ALSdk.shared().settings.isVerboseLoggingEnabled = verboseLogging
        let configuration = ALSdkInitializationConfiguration(sdkKey: sdkKey) { [testDevices] builder in
            builder.mediationProvider = ALMediationProviderMAX
            // MAX has no public test unit; test ads need the device's IDFA registered here.
            builder.testDeviceAdvertisingIdentifiers = testDevices
        }
        AdvergicAdapterLog.d("Starting AppLovin \(ALSdk.version)")
        ALSdk.shared().initialize(with: configuration) { [weak self] _ in
            self?.markReady()
        }
    }
}

// MARK: Banner

final class AppLovinBannerAdapter: NSObject, AdvergicBannerAdapter, MAAdViewAdDelegate, MAAdRevenueDelegate {

    private var adView: MAAdView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard adView == nil else { return }
        self.callbacks = callbacks
        if AppLovinSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("AppLovin banner ad unit is not set")
            return
        }
        let view = MAAdView(adUnitIdentifier: adUnitId, adFormat: Self.format(size))
        view.delegate = self
        view.revenueDelegate = self
        // The chain decides when to request again; MAX's own refresh would fill behind its back.
        view.setExtraParameterForKey("allow_pause_auto_refresh_immediately", value: "true")
        view.stopAutoRefresh()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        adView = view
        AdvergicAdapterLog.d("Requesting AppLovin banner for \(adUnitId) at \(size)")
        view.loadAd()
    }

    func destroy() {
        adView?.delegate = nil
        adView?.revenueDelegate = nil
        adView?.removeFromSuperview()
        adView = nil
        callbacks = nil
    }

    func didLoad(_ ad: MAAd) {
        AdvergicAdapterLog.d("AppLovin banner loaded from \(ad.networkName)")
        callbacks?.onLoaded()
    }

    func didFailToLoadAd(forAdUnitIdentifier adUnitIdentifier: String, withError error: MAError) {
        let message = AppLovinSupport.message(error)
        AdvergicAdapterLog.w("AppLovin banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func didClick(_ ad: MAAd) { callbacks?.onClicked() }
    func didDisplay(_ ad: MAAd) {}
    func didHide(_ ad: MAAd) {}
    func didFail(toDisplay ad: MAAd, withError error: MAError) {}
    func didExpand(_ ad: MAAd) {}
    func didCollapse(_ ad: MAAd) {}

    func didPayRevenue(for ad: MAAd) {
        guard let callbacks else { return }
        AppLovinSupport.report(ad, onRevenue: callbacks.onRevenue, onUnavailable: callbacks.onRevenueUnavailable)
    }

    static func format(_ size: AdvergicAdSize) -> MAAdFormat {
        switch size {
        case .mediumRectangle: return .mrec
        case .leaderboard: return .leader
        default: return .banner
        }
    }
}

// MARK: Fullscreen

final class AppLovinFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    MARewardedAdDelegate, MAAdRevenueDelegate {

    private var interstitial: MAInterstitialAd?
    private var rewarded: MARewardedAd?
    private var appOpen: MAAppOpenAd?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var format: AdvergicAdFormat = .interstitial

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.format = format
        clear()
        if AppLovinSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("AppLovin \(format) ad unit is not set")
            return
        }
        AdvergicAdapterLog.d("Requesting AppLovin \(format) for \(adUnitId)")
        switch format {
        case .interstitial:
            let ad = MAInterstitialAd(adUnitIdentifier: adUnitId)
            ad.delegate = self
            ad.revenueDelegate = self
            interstitial = ad
            ad.load()
        case .rewarded:
            // MAX keeps one rewarded instance per unit, process-wide.
            let ad = MARewardedAd.shared(withAdUnitIdentifier: adUnitId)
            ad.delegate = self
            ad.revenueDelegate = self
            rewarded = ad
            ad.load()
        case .appOpen:
            let ad = MAAppOpenAd(adUnitIdentifier: adUnitId)
            ad.delegate = self
            ad.revenueDelegate = self
            appOpen = ad
            ad.load()
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial, interstitial.isReady { interstitial.show(forPlacement: nil, customData: nil, viewController: viewController) }
        else if let rewarded, rewarded.isReady { rewarded.show(forPlacement: nil, customData: nil, viewController: viewController) }
        else if let appOpen, appOpen.isReady { appOpen.show() }
        else { AdvergicAdapterLog.w("AppLovin show called with no ready ad") }
    }

    func destroy() {
        clear()
        callbacks = nil
    }

    private func clear() {
        interstitial?.delegate = nil
        rewarded?.delegate = nil
        appOpen?.delegate = nil
        interstitial = nil
        rewarded = nil
        appOpen = nil
    }

    func didLoad(_ ad: MAAd) {
        AdvergicAdapterLog.d("AppLovin \(ad.format.label) loaded from \(ad.networkName)")
        callbacks?.onLoaded()
    }

    func didFailToLoadAd(forAdUnitIdentifier adUnitIdentifier: String, withError error: MAError) {
        let message = AppLovinSupport.message(error)
        AdvergicAdapterLog.w("AppLovin \(format) failed: \(message)")
        callbacks?.onFailed(message)
    }

    func didDisplay(_ ad: MAAd) { callbacks?.onShown() }
    func didClick(_ ad: MAAd) { callbacks?.onClicked() }

    func didHide(_ ad: MAAd) {
        clear()
        callbacks?.onDismissed()
    }

    func didFail(toDisplay ad: MAAd, withError error: MAError) {
        clear()
        callbacks?.onFailed("show failed: \(AppLovinSupport.message(error))")
    }

    func didRewardUser(for ad: MAAd, with reward: MAReward) {
        AdvergicAdapterLog.d("AppLovin reward earned: \(reward.amount) \(reward.label)")
        callbacks?.onRewardEarned(reward.amount, reward.label)
    }

    func didPayRevenue(for ad: MAAd) {
        guard let callbacks else { return }
        AppLovinSupport.report(ad, onRevenue: callbacks.onRevenue, onUnavailable: callbacks.onRevenueUnavailable)
    }
}
#endif
