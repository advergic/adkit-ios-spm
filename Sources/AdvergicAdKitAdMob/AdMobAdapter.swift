#if canImport(UIKit) && canImport(GoogleMobileAds)
import Foundation
import GoogleMobileAds
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Google Mobile Ads, discovered by the core under this Objective-C name.
///
/// Needs no key at runtime: the app id lives in `Info.plist` (`GADApplicationIdentifier`), and
/// Google's test units fill for anyone.
@objc(AdvergicAdMobAdapter)
final class AdMobAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .admobTest

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        AdMobInitializer(testDeviceIds: setup.testDevices(fallback: setup.config.testDeviceAdvertisingIds))
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { AdMobBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { AdMobFullscreenAdapter() }
    func makeNativeAdapter() -> AdvergicNativeAdapter { AdMobNativeAdapter() }

    /// Google's Ad Inspector: per-network waterfall, latency and errors for the last requests.
    func showDebugPanel(from viewController: UIViewController) -> Bool {
        MobileAds.shared.presentAdInspector(from: viewController) { error in
            if let error { AdvergicAdapterLog.w("AdMob Ad Inspector failed: \(error.localizedDescription)") }
        }
        return true
    }
}

final class AdMobInitializer: AdvergicBaseInitializer {

    private let testDeviceIds: [String]

    init(testDeviceIds: [String]) {
        self.testDeviceIds = testDeviceIds
        super.init(networkName: AdvergicAdNetwork.admobTest.name)
    }

    override func start() {
        // GMA terminates the app at launch without this key, so reaching here means it exists —
        // but a missing key in a unit-test host is worth a clear line rather than a crash report.
        if Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") == nil {
            markUnavailable("GADApplicationIdentifier is missing from Info.plist — Google Mobile Ads cannot start")
            return
        }
        if !testDeviceIds.isEmpty {
            MobileAds.shared.requestConfiguration.testDeviceIdentifiers = testDeviceIds
        }
        MobileAds.shared.start { [weak self] status in
            for (adapter, state) in status.adapterStatusesByClassName {
                AdvergicAdapterLog.d("AdMob adapter \(adapter): \(state.state.rawValue) \(state.description)")
            }
            self?.markReady()
        }
    }
}

// MARK: Revenue

enum AdMobRevenue {

    static func make(_ value: AdValue, adUnitId: String, responseInfo: ResponseInfo?) -> AdvergicAdRevenue {
        let amount = value.value.doubleValue
        AdvergicAdapterLog.d("AdMob AdValue raw: value=\(value.value), currency=\(value.currencyCode), precision=\(value.precision.rawValue)")
        return AdvergicAdRevenue(
            amount: amount,
            currencyCode: value.currencyCode,
            amountUsd: value.currencyCode.caseInsensitiveCompare("USD") == .orderedSame ? amount : nil,
            precision: precisionName(value.precision),
            // The adapter that actually served under AdMob mediation, when there was one.
            network: responseInfo?.loadedAdNetworkResponseInfo?.adNetworkClassName ?? "admob",
            adUnitId: adUnitId
        )
    }

    static func precisionName(_ precision: AdValuePrecision) -> String {
        switch precision {
        case .unknown: return "UNKNOWN"
        case .estimated: return "ESTIMATED"
        case .publisherProvided: return "PUBLISHER_PROVIDED"
        case .precise: return "PRECISE"
        @unknown default: return "UNRECOGNISED(\(precision.rawValue))"
        }
    }

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }
}

// MARK: Banner

final class AdMobBannerAdapter: NSObject, AdvergicBannerAdapter, BannerViewDelegate {

    private var bannerView: BannerView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks

        let view = BannerView(adSize: Self.adSize(size))
        view.adUnitID = adUnitId
        view.delegate = self
        view.rootViewController = container.advergicViewController ?? UIView.advergicTopViewController
        view.paidEventHandler = { [weak view, weak self] value in
            let revenue = AdMobRevenue.make(value, adUnitId: adUnitId, responseInfo: view?.responseInfo)
            AdvergicAdapterLog.d("AdMob revenue: \(revenue)")
            self?.callbacks?.onRevenue(revenue)
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        bannerView = view

        AdvergicAdapterLog.d("Requesting AdMob banner for \(adUnitId)")
        view.load(Request())
    }

    func destroy() {
        bannerView?.delegate = nil
        bannerView?.paidEventHandler = nil
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        AdvergicAdapterLog.d("AdMob banner loaded; responseInfo: \(bannerView.responseInfo?.description ?? "none")")
        callbacks?.onLoaded()
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        let message = AdMobRevenue.message(error)
        AdvergicAdapterLog.w("AdMob banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func bannerViewDidRecordClick(_ bannerView: BannerView) {
        callbacks?.onClicked()
    }

    /// Google's named sizes carry demand that arbitrary dimensions do not.
    static func adSize(_ size: AdvergicAdSize) -> AdSize {
        switch size {
        case .banner: return AdSizeBanner
        case .largeBanner: return AdSizeLargeBanner
        case .mediumRectangle: return AdSizeMediumRectangle
        case .leaderboard: return AdSizeLeaderboard
        default: return adSizeFor(cgSize: CGSize(width: size.width, height: size.height))
        }
    }
}

// MARK: Fullscreen

/// Interstitial, rewarded and app open. The three have no common load API, so each is held in
/// its own slot and dispatched on show.
final class AdMobFullscreenAdapter: NSObject, AdvergicFullscreenAdapter, FullScreenContentDelegate {

    private var interstitial: InterstitialAd?
    private var rewarded: RewardedAd?
    private var appOpen: AppOpenAd?
    private var callbacks: AdvergicFullscreenCallbacks?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        clear()
        AdvergicAdapterLog.d("Requesting AdMob \(format) for \(adUnitId)")

        switch format {
        case .interstitial:
            InterstitialAd.load(with: adUnitId, request: Request()) { [weak self] ad, error in
                guard let self else { return }
                if let ad {
                    self.interstitial = ad
                    ad.fullScreenContentDelegate = self
                    ad.paidEventHandler = { [weak self, weak ad] value in
                        self?.callbacks?.onRevenue(AdMobRevenue.make(value, adUnitId: adUnitId, responseInfo: ad?.responseInfo))
                    }
                    self.loaded(format, adUnitId)
                } else {
                    self.failed(format, error)
                }
            }

        case .rewarded:
            RewardedAd.load(with: adUnitId, request: Request()) { [weak self] ad, error in
                guard let self else { return }
                if let ad {
                    self.rewarded = ad
                    ad.fullScreenContentDelegate = self
                    ad.paidEventHandler = { [weak self, weak ad] value in
                        self?.callbacks?.onRevenue(AdMobRevenue.make(value, adUnitId: adUnitId, responseInfo: ad?.responseInfo))
                    }
                    self.loaded(format, adUnitId)
                } else {
                    self.failed(format, error)
                }
            }

        case .appOpen:
            AppOpenAd.load(with: adUnitId, request: Request()) { [weak self] ad, error in
                guard let self else { return }
                if let ad {
                    self.appOpen = ad
                    ad.fullScreenContentDelegate = self
                    ad.paidEventHandler = { [weak self, weak ad] value in
                        self?.callbacks?.onRevenue(AdMobRevenue.make(value, adUnitId: adUnitId, responseInfo: ad?.responseInfo))
                    }
                    self.loaded(format, adUnitId)
                } else {
                    self.failed(format, error)
                }
            }
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial {
            interstitial.present(from: viewController)
        } else if let appOpen {
            appOpen.present(from: viewController)
        } else if let rewarded {
            rewarded.present(from: viewController) { [weak self, weak rewarded] in
                guard let reward = rewarded?.adReward else { return }
                AdvergicAdapterLog.d("AdMob reward: \(reward.amount) \(reward.type)")
                self?.callbacks?.onRewardEarned(reward.amount.intValue, reward.type)
            }
        } else {
            AdvergicAdapterLog.w("AdMob show called with no cached ad")
        }
    }

    func destroy() {
        clear()
        callbacks = nil
    }

    private func clear() {
        interstitial = nil
        rewarded = nil
        appOpen = nil
    }

    private func loaded(_ format: AdvergicAdFormat, _ adUnitId: String) {
        AdvergicAdapterLog.d("AdMob \(format) loaded for \(adUnitId)")
        callbacks?.onLoaded()
    }

    private func failed(_ format: AdvergicAdFormat, _ error: Error?) {
        let message = error.map(AdMobRevenue.message) ?? "no ad and no error"
        AdvergicAdapterLog.w("AdMob \(format) failed: \(message)")
        callbacks?.onFailed(message)
    }

    // FullScreenContentDelegate

    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        callbacks?.onShown()
    }

    /// AdMob's fullscreen ads are single-use; a spent one silently shows nothing.
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        clear()
        callbacks?.onDismissed()
    }

    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        let message = "show failed: \(AdMobRevenue.message(error))"
        AdvergicAdapterLog.w("AdMob \(message)")
        clear()
        callbacks?.onFailed(message)
    }

    func adDidRecordClick(_ ad: FullScreenPresentingAd) {
        callbacks?.onClicked()
    }
}

// MARK: Native

final class AdMobNativeAdapter: NSObject, AdvergicNativeAdapter, NativeAdLoaderDelegate, NativeAdDelegate {

    private var loader: AdLoader?
    private var nativeAd: NativeAd?
    private var adView: NativeAdView?
    private var callbacks: AdvergicBannerCallbacks?
    private var adUnitId = ""

    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        guard adView == nil else { return }
        self.callbacks = callbacks
        self.adUnitId = adUnitId

        if adUnitId.isEmpty || adUnitId.hasPrefix("REPLACE_WITH") {
            let message = "AdMob native ad unit is not set"
            AdvergicAdapterLog.e(message)
            callbacks.onFailed(message)
            return
        }

        let view = NativeAdView()
        let template = AdvergicNativeTemplateView()
        AdvergicNativeTemplateView.pin(template, in: view)
        AdvergicNativeTemplateView.pin(view, in: container)
        adView = view

        let loader = AdLoader(
            adUnitID: adUnitId,
            rootViewController: container.advergicViewController ?? UIView.advergicTopViewController,
            adTypes: [.native],
            options: nil
        )
        loader.delegate = self
        self.loader = loader
        AdvergicAdapterLog.d("Requesting AdMob native for \(adUnitId)")
        loader.load(Request())
    }

    func destroy() {
        nativeAd?.delegate = nil
        nativeAd?.paidEventHandler = nil
        nativeAd = nil
        loader = nil
        adView?.removeFromSuperview()
        adView = nil
        callbacks = nil
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        guard let adView, let template = adView.subviews.first as? AdvergicNativeTemplateView else { return }
        self.nativeAd = nativeAd
        nativeAd.delegate = self
        nativeAd.paidEventHandler = { [weak self, weak nativeAd] value in
            guard let self else { return }
            self.callbacks?.onRevenue(AdMobRevenue.make(value, adUnitId: self.adUnitId, responseInfo: nativeAd?.responseInfo))
        }

        template.bind(headline: nativeAd.headline, advertiser: nativeAd.advertiser, body: nativeAd.body,
                      callToAction: nativeAd.callToAction, icon: nativeAd.icon?.image)
        let media = MediaView()
        template.setMedia(media)

        // Every asset view is registered before `nativeAd` is set, or Google's click and
        // impression tracking never gets wired to them.
        adView.headlineView = template.headlineLabel
        adView.advertiserView = template.advertiserLabel
        adView.bodyView = template.bodyLabel
        adView.callToActionView = template.callToActionButton
        adView.iconView = template.iconView
        adView.mediaView = media
        media.mediaContent = nativeAd.mediaContent
        adView.nativeAd = nativeAd

        callbacks?.onLoaded()
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        let message = AdMobRevenue.message(error)
        AdvergicAdapterLog.w("AdMob native failed: \(message)")
        callbacks?.onFailed(message)
    }

    func nativeAdDidRecordClick(_ nativeAd: NativeAd) {
        callbacks?.onClicked()
    }
}
#endif
