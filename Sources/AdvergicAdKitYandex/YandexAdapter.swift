#if canImport(UIKit) && canImport(YandexMobileAds)
import Foundation
import UIKit
import YandexMobileAds
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Yandex Mobile Ads. Takes no app id — the ad unit encodes it (`R-M-«app»-«unit»`), so there
/// is nothing to configure. Yandex's public demo units (`demo-banner-yandex`, …) fill with no
/// account.
@objc(AdvergicYandexAdapter)
final class YandexAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .yandex

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        YandexInitializer(verboseLogging: setup.enableLogging)
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { YandexBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { YandexFullscreenAdapter() }
    func makeNativeAdapter() -> AdvergicNativeAdapter { YandexNativeAdapter() }

    /// Yandex's debug panel: adapter wiring and initialization state per mediated network.
    func showDebugPanel(from viewController: UIViewController) -> Bool {
        YandexAds.showDebugPanel()
        return true
    }
}

final class YandexInitializer: AdvergicBaseInitializer {

    private let verboseLogging: Bool

    init(verboseLogging: Bool) {
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.yandex.name)
    }

    override func start() {
        if verboseLogging { YandexAds.enableLogging() }
        AdvergicAdapterLog.d("Yandex SDK \(YandexAds.sdkVersion.stringValue)")
        YandexAds.initializeSDK { [weak self] in self?.markReady() }
    }
}

// MARK: Revenue

/// Yandex reports impression-level revenue as a free-form JSON string, the same for every format.
enum YandexRevenue {

    /// Seen shapes put the amount in a nested `revenue` object or flat on the root.
    static func parse(_ raw: String, adUnitId: String) -> AdvergicAdRevenue {
        let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        let nested = json["revenue"] as? [String: Any]

        let amount = number(nested?["value"]) ?? number(json["revenue"]) ?? 0
        let currency = nonEmpty(nested?["currency"] as? String) ?? nonEmpty(json["currency"] as? String) ?? "USD"
        // Yandex sends a USD figure alongside the account-currency one.
        let usd = number(json["revenueUSD"]) ?? (currency.uppercased() == "USD" ? amount : nil)
        let network = nonEmpty((json["network"] as? [String: Any])?["name"] as? String)
            ?? nonEmpty(json["network_name"] as? String) ?? "yandex"

        return AdvergicAdRevenue(
            amount: amount,
            currencyCode: currency,
            amountUsd: usd,
            precision: nonEmpty(json["precision"] as? String) ?? "unknown",
            network: network,
            adUnitId: nonEmpty(json["ad_unit_id"] as? String) ?? adUnitId
        )
    }

    /// A payload-less impression means mediated demand whose price the mediator doesn't know:
    /// "no price", distinct from "priced at zero".
    static func report(_ data: ImpressionData?, adUnitId: String,
                       onRevenue: (AdvergicAdRevenue) -> Void, onUnavailable: (String) -> Void) {
        guard let raw = data?.rawData, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onUnavailable("Yandex reported the impression without revenue data")
            return
        }
        AdvergicAdapterLog.d("Yandex impression raw: \(raw)")
        onRevenue(parse(raw, adUnitId: adUnitId))
    }

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

// MARK: Banner

final class YandexBannerAdapter: NSObject, AdvergicBannerAdapter, BannerAdViewDelegate {

    private var bannerView: BannerAdView?
    private var callbacks: AdvergicBannerCallbacks?
    private var adUnitId = ""

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks
        self.adUnitId = adUnitId

        // Fixed, not inline: the slot promised the host an exact size.
        let view = BannerAdView(adSize: .fixed(width: CGFloat(size.width), height: CGFloat(size.height)))
        view.delegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        bannerView = view

        AdvergicAdapterLog.d("Requesting Yandex banner for \(adUnitId)")
        view.loadAd(with: AdRequest(adUnitID: adUnitId))
    }

    func destroy() {
        bannerView?.delegate = nil
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func bannerAdViewDidLoad(_ bannerAdView: BannerAdView) {
        AdvergicAdapterLog.d("Yandex banner loaded: \(bannerAdView.adInfo.map { "\($0.adUnitID) creatives=\($0.creatives.count)" } ?? "no info")")
        callbacks?.onLoaded()
    }

    func bannerAdViewDidFailLoading(_ bannerAdView: BannerAdView, error: Error) {
        let message = YandexRevenue.message(error)
        AdvergicAdapterLog.w("Yandex banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func bannerAdViewDidClick(_ bannerAdView: BannerAdView) {
        callbacks?.onClicked()
    }

    func bannerAdView(_ bannerAdView: BannerAdView, didTrackImpression impressionData: ImpressionData?) {
        guard let callbacks else { return }
        YandexRevenue.report(impressionData, adUnitId: adUnitId,
                             onRevenue: callbacks.onRevenue, onUnavailable: callbacks.onRevenueUnavailable)
    }
}

// MARK: Fullscreen

final class YandexFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    InterstitialAdDelegate, RewardedAdDelegate, AppOpenAdDelegate {

    // Loaders must outlive the request.
    private let interstitialLoader = InterstitialAdLoader()
    private let rewardedLoader = RewardedAdLoader()
    private let appOpenLoader = AppOpenAdLoader()

    private var interstitial: InterstitialAd?
    private var rewarded: RewardedAd?
    private var appOpen: AppOpenAd?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var adUnitId = ""

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.adUnitId = adUnitId
        clear()
        let request = AdRequest(adUnitID: adUnitId)
        AdvergicAdapterLog.d("Requesting Yandex \(format) for \(adUnitId)")

        switch format {
        case .interstitial:
            interstitialLoader.loadAd(with: request) { [weak self] (ad: InterstitialAd?, error: Error?) in
                guard let self else { return }
                if let ad { ad.delegate = self; self.interstitial = ad; self.loaded(format) } else { self.failed(format, error) }
            }
        case .rewarded:
            rewardedLoader.loadAd(with: request) { [weak self] (ad: RewardedAd?, error: Error?) in
                guard let self else { return }
                if let ad { ad.delegate = self; self.rewarded = ad; self.loaded(format) } else { self.failed(format, error) }
            }
        case .appOpen:
            appOpenLoader.loadAd(with: request) { [weak self] (ad: AppOpenAd?, error: Error?) in
                guard let self else { return }
                if let ad { ad.delegate = self; self.appOpen = ad; self.loaded(format) } else { self.failed(format, error) }
            }
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial { interstitial.show(from: viewController) }
        else if let rewarded { rewarded.show(from: viewController) }
        else if let appOpen { appOpen.show(from: viewController) }
        else { AdvergicAdapterLog.w("Yandex show called with no cached ad") }
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

    private func loaded(_ format: AdvergicAdFormat) {
        AdvergicAdapterLog.d("Yandex \(format) loaded for \(adUnitId)")
        callbacks?.onLoaded()
    }

    private func failed(_ format: AdvergicAdFormat, _ error: Error?) {
        let message = error.map(YandexRevenue.message) ?? "no ad and no error"
        AdvergicAdapterLog.w("Yandex \(format) failed: \(message)")
        callbacks?.onFailed(message)
    }

    private func shown() { callbacks?.onShown() }
    private func dismissed() { clear(); callbacks?.onDismissed() }
    private func clicked() { callbacks?.onClicked() }
    private func failedToShow(_ error: Error) {
        let message = "show failed: \(YandexRevenue.message(error))"
        AdvergicAdapterLog.w("Yandex \(message)")
        clear()
        callbacks?.onFailed(message)
    }
    private func impression(_ data: ImpressionData?) {
        guard let callbacks else { return }
        YandexRevenue.report(data, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                             onUnavailable: callbacks.onRevenueUnavailable)
    }

    func interstitialAdDidShow(_ interstitialAd: InterstitialAd) { shown() }
    func interstitialAdDidDismiss(_ interstitialAd: InterstitialAd) { dismissed() }
    func interstitialAdDidClick(_ interstitialAd: InterstitialAd) { clicked() }
    func interstitialAd(_ interstitialAd: InterstitialAd, didFailToShow error: Error) { failedToShow(error) }
    func interstitialAd(_ interstitialAd: InterstitialAd, didTrackImpression impressionData: ImpressionData?) { impression(impressionData) }

    func rewardedAd(_ rewardedAd: RewardedAd, didReward reward: Reward) {
        AdvergicAdapterLog.d("Yandex reward: \(reward.amount) \(reward.type)")
        callbacks?.onRewardEarned(reward.amount, reward.type)
    }
    func rewardedAdDidShow(_ rewardedAd: RewardedAd) { shown() }
    func rewardedAdDidDismiss(_ rewardedAd: RewardedAd) { dismissed() }
    func rewardedAdDidClick(_ rewardedAd: RewardedAd) { clicked() }
    func rewardedAd(_ rewardedAd: RewardedAd, didFailToShow error: Error) { failedToShow(error) }
    func rewardedAd(_ rewardedAd: RewardedAd, didTrackImpression impressionData: ImpressionData?) { impression(impressionData) }

    func appOpenAdDidShow(_ appOpenAd: AppOpenAd) { shown() }
    func appOpenAdDidDismiss(_ appOpenAd: AppOpenAd) { dismissed() }
    func appOpenAdDidClick(_ appOpenAd: AppOpenAd) { clicked() }
    func appOpenAd(_ appOpenAd: AppOpenAd, didFailToShow error: Error) { failedToShow(error) }
    func appOpenAd(_ appOpenAd: AppOpenAd, didTrackImpression impressionData: ImpressionData?) { impression(impressionData) }
}

// MARK: Native

/// Yandex publishes no template view, so the SDK's template is placed inside Yandex's
/// `NativeAdView` and its labels registered. Age, sponsor and warning are legally required
/// disclosures on Yandex inventory, so they get labels of their own.
final class YandexNativeAdapter: NSObject, AdvergicNativeAdapter, NativeAdDelegate {

    private let loader = NativeAdLoader()
    private var nativeAd: NativeAd?
    private var adView: NativeAdView?
    private var callbacks: AdvergicBannerCallbacks?
    private var adUnitId = ""

    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        guard adView == nil else { return }
        self.callbacks = callbacks
        self.adUnitId = adUnitId

        let view = NativeAdView()
        let template = AdvergicNativeTemplateView()
        AdvergicNativeTemplateView.pin(template, in: view)
        AdvergicNativeTemplateView.pin(view, in: container)
        adView = view

        AdvergicAdapterLog.d("Requesting Yandex native for \(adUnitId)")
        loader.loadAd(with: AdRequest(adUnitID: adUnitId)) { [weak self] (ad: NativeAd?, error: Error?) in
            guard let self else { return }
            if let ad {
                self.bind(ad, template: template)
            } else {
                let message = error.map(YandexRevenue.message) ?? "no ad and no error"
                AdvergicAdapterLog.w("Yandex native failed: \(message)")
                self.callbacks?.onFailed(message)
            }
        }
    }

    func destroy() {
        nativeAd?.delegate = nil
        nativeAd = nil
        adView?.removeFromSuperview()
        adView = nil
        callbacks = nil
    }

    private func bind(_ ad: NativeAd, template: AdvergicNativeTemplateView) {
        guard let adView else { return }
        nativeAd = ad
        ad.delegate = self

        let media = NativeMediaView()
        template.setMedia(media)
        // Yandex wires its own tap handling onto the button.
        template.callToActionButton.isUserInteractionEnabled = true

        adView.titleLabel = template.headlineLabel
        adView.bodyLabel = template.bodyLabel
        adView.sponsoredLabel = template.advertiserLabel
        adView.callToActionButton = template.callToActionButton
        adView.iconImageView = template.iconView
        adView.mediaView = media
        adView.domainLabel = template.addDisclosureLabel()
        adView.ageLabel = template.addDisclosureLabel()
        adView.warningLabel = template.addDisclosureLabel()

        do {
            try ad.bind(with: adView)
            template.iconView.isHidden = ad.adAssets().icon == nil
            AdvergicAdapterLog.d("Yandex native loaded (\(ad.adType.rawValue)) for \(adUnitId)")
            callbacks?.onLoaded()
        } catch {
            let message = "bind failed: \(YandexRevenue.message(error))"
            AdvergicAdapterLog.w("Yandex native \(message)")
            callbacks?.onFailed(message)
        }
    }

    func nativeAdDidClick(_ ad: NativeAd) {
        callbacks?.onClicked()
    }

    func nativeAd(_ ad: NativeAd, didTrackImpression impressionData: ImpressionData?) {
        guard let callbacks else { return }
        YandexRevenue.report(impressionData, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                             onUnavailable: callbacks.onRevenueUnavailable)
    }
}
#endif
