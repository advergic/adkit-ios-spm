#if canImport(UIKit) && canImport(IronSource)
import Foundation
import IronSource
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// ironSource, through its current LevelPlay API. A mediator: it prices whatever demand wins,
/// reported on each ad's impression-data delegate. Addressed by ad unit id; no app-open, and
/// native is not wired (as on Android).
@objc(AdvergicIronSourceAdapter)
final class IronSourceAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .ironSource

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        IronSourceInitializer(appKey: setup.credential("app_key", fallback: setup.config.ironSourceAppKey))
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { IronSourceBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { IronSourceFullscreenAdapter() }

    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .ironSource, reason: .notIntegrated)
    }
}

enum IronSourceSupport {

    static func isPlaceholder(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespaces).isEmpty || id.hasPrefix("REPLACE_WITH")
    }

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    /// LevelPlay reports every price in USD; the payload carries no currency field.
    static func report(_ data: LPMImpressionData, adUnitId: String,
                       onRevenue: (AdvergicAdRevenue) -> Void, onUnavailable: (String) -> Void) {
        guard let amount = data.revenue?.doubleValue, amount > 0 else {
            onUnavailable("ironSource disclosed no revenue for this fill (\(data.adNetwork ?? "unknown"))")
            return
        }
        onRevenue(AdvergicAdRevenue(
            amount: amount,
            currencyCode: "USD",
            amountUsd: amount,
            precision: data.precision.flatMap { $0.isEmpty ? nil : $0 } ?? "mediation",
            network: data.adNetwork.flatMap { $0.isEmpty ? nil : $0 } ?? "ironsource",
            adUnitId: data.mediationAdUnitId ?? adUnitId
        ))
    }
}

final class IronSourceInitializer: AdvergicBaseInitializer {

    private let appKey: String

    init(appKey: String) {
        self.appKey = appKey
        super.init(networkName: AdvergicAdNetwork.ironSource.name)
    }

    override func start() {
        if isPlaceholder(appKey) {
            markUnavailable(missingCredential("app key"))
            return
        }
        AdvergicAdapterLog.d("Starting ironSource LevelPlay \(LevelPlay.sdkVersion()) with app key \(appKey)")
        let request = LPMInitRequestBuilder(appKey: appKey).build()
        LevelPlay.initWith(request) { [weak self] _, error in
            if let error {
                self?.markUnavailable("ironSource init failed: \(IronSourceSupport.message(error))")
            } else {
                self?.markReady()
            }
        }
    }
}

// MARK: Banner

final class IronSourceBannerAdapter: NSObject, AdvergicBannerAdapter, LPMBannerAdViewDelegate, LPMImpressionDataDelegate {

    private var bannerView: LPMBannerAdView?
    private var callbacks: AdvergicBannerCallbacks?
    private var adUnitId = ""

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks
        self.adUnitId = adUnitId
        if IronSourceSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("ironSource banner ad unit is not set")
            return
        }
        guard let controller = container.advergicViewController ?? UIView.advergicTopViewController else {
            callbacks.onFailed("ironSource needs a view controller to load a banner")
            return
        }
        let config = LPMBannerAdViewConfigBuilder().set(adSize: Self.adSize(size)).build()
        let view = LPMBannerAdView(adUnitId: adUnitId, config: config)
        view.setDelegate(self)
        view.setImpressionDataDelegate(self)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        bannerView = view
        AdvergicAdapterLog.d("Requesting ironSource banner for \(adUnitId) at \(size)")
        view.loadAd(with: controller)
        // The chain decides when to ask again.
        view.pauseAutoRefresh()
    }

    func destroy() {
        bannerView?.destroy()
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func didLoadAd(with adInfo: LPMAdInfo) {
        AdvergicAdapterLog.d("ironSource banner loaded from \(adInfo.adNetwork)")
        callbacks?.onLoaded()
    }

    func didFailToLoadAd(withAdUnitId adUnitId: String, error: Error) {
        let message = IronSourceSupport.message(error)
        AdvergicAdapterLog.w("ironSource banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func didClickAd(with adInfo: LPMAdInfo) {
        callbacks?.onClicked()
    }

    func impressionDataDidSucceed(_ impressionData: LPMImpressionData) {
        guard let callbacks else { return }
        IronSourceSupport.report(impressionData, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                                 onUnavailable: callbacks.onRevenueUnavailable)
    }

    static func adSize(_ size: AdvergicAdSize) -> LPMAdSize {
        switch size {
        case .banner: return .banner()
        case .largeBanner: return .large()
        case .mediumRectangle: return .mediumRectangle()
        case .leaderboard: return .leaderBoard()
        default: return .customSize(withWidth: size.width, height: size.height)
        }
    }
}

// MARK: Fullscreen

final class IronSourceFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    LPMInterstitialAdDelegate, LPMRewardedAdDelegate, LPMImpressionDataDelegate {

    private var interstitial: LPMInterstitialAd?
    private var rewarded: LPMRewardedAd?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var adUnitId = ""

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.adUnitId = adUnitId
        interstitial = nil
        rewarded = nil
        if format == .appOpen {
            callbacks.onFailed("IRONSOURCE has no app-open format")
            return
        }
        if IronSourceSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("ironSource \(format) ad unit is not set")
            return
        }
        AdvergicAdapterLog.d("Requesting ironSource \(format) for \(adUnitId)")
        if format == .rewarded {
            let ad = LPMRewardedAd(adUnitId: adUnitId)
            ad.setDelegate(self)
            ad.setImpressionDataDelegate(self)
            rewarded = ad
            ad.loadAd()
        } else {
            let ad = LPMInterstitialAd(adUnitId: adUnitId)
            ad.setDelegate(self)
            ad.setImpressionDataDelegate(self)
            interstitial = ad
            ad.loadAd()
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial, interstitial.isAdReady() {
            interstitial.showAd(viewController: viewController, placementName: nil)
        } else if let rewarded, rewarded.isAdReady() {
            rewarded.showAd(viewController: viewController, placementName: nil)
        } else {
            AdvergicAdapterLog.w("ironSource show called with no ready ad")
        }
    }

    func destroy() {
        interstitial = nil
        rewarded = nil
        callbacks = nil
    }

    func didLoadAd(with adInfo: LPMAdInfo) { callbacks?.onLoaded() }

    func didFailToLoadAd(withAdUnitId adUnitId: String, error: Error) {
        let message = IronSourceSupport.message(error)
        AdvergicAdapterLog.w("ironSource fullscreen failed: \(message)")
        callbacks?.onFailed(message)
    }

    func didDisplayAd(with adInfo: LPMAdInfo) { callbacks?.onShown() }

    func didFailToDisplayAd(with adInfo: LPMAdInfo, error: Error) {
        callbacks?.onFailed("show failed: \(IronSourceSupport.message(error))")
    }

    func didClickAd(with adInfo: LPMAdInfo) { callbacks?.onClicked() }

    func didCloseAd(with adInfo: LPMAdInfo) {
        interstitial = nil
        rewarded = nil
        callbacks?.onDismissed()
    }

    func didRewardAd(with adInfo: LPMAdInfo, reward: LPMReward) {
        callbacks?.onRewardEarned(reward.amount, reward.name)
    }

    func impressionDataDidSucceed(_ impressionData: LPMImpressionData) {
        guard let callbacks else { return }
        IronSourceSupport.report(impressionData, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                                 onUnavailable: callbacks.onRevenueUnavailable)
    }
}
#endif
