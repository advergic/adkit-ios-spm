#if canImport(UIKit) && canImport(VungleAdsSDK)
import Foundation
import UIKit
import VungleAdsSDK
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Liftoff Monetize (formerly Vungle). A demand source that discloses no price. App ids and
/// placements are per platform; placements must be **non-bidding** — a header-bidding placement
/// rejects a plain load.
@objc(AdvergicLiftoffAdapter)
final class LiftoffAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .liftoff

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        LiftoffInitializer(
            appId: setup.credential("app_id", fallback: setup.config.liftoffAppId),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { LiftoffBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { LiftoffFullscreenAdapter() }
    func makeNativeAdapter() -> AdvergicNativeAdapter { LiftoffNativeAdapter() }

    /// Collected for a future server-side auction; nothing consumes it yet (as on Android).
    func bidderToken() async -> String? {
        let token = VungleAds.getBiddingToken()
        return token.isEmpty ? nil : token
    }
}

enum Liftoff {
    static let noPrice = "Liftoff discloses no price to the SDK"

    static func message(_ error: Error, stage: String? = nil) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code)\(stage.map { ", stage=\($0)" } ?? ""))"
    }

    static func isPlaceholder(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespaces).isEmpty || id.hasPrefix("REPLACE_WITH")
    }
}

final class LiftoffInitializer: AdvergicBaseInitializer {

    private let appId: String
    private let verboseLogging: Bool

    init(appId: String, verboseLogging: Bool) {
        self.appId = appId
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.liftoff.name)
    }

    override func start() {
        if isPlaceholder(appId) {
            markUnavailable(missingCredential("app id"))
            return
        }
        VungleAds.setDebugLoggingEnabled(verboseLogging)
        VungleAds.setIntegrationName("advergic", version: "")
        // Logged because the host app can override this, and a placement only works under the
        // app that owns it.
        AdvergicAdapterLog.d("Starting Liftoff \(VungleAds.sdkVersion) with app id \(appId)")
        VungleAds.initWithAppId(appId) { [weak self] error in
            if let error {
                self?.markUnavailable("Liftoff init failed: \(Liftoff.message(error))")
            } else {
                self?.markReady()
            }
        }
    }
}

// MARK: Banner

final class LiftoffBannerAdapter: NSObject, AdvergicBannerAdapter, VungleBannerViewDelegate {

    private var bannerView: VungleBannerView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks

        if Liftoff.isPlaceholder(adUnitId) {
            callbacks.onFailed("Liftoff banner placement id is not set")
            return
        }
        // A placement created as interstitial answers a banner request with a server error that
        // names nothing, so say up front what kind this one is.
        AdvergicAdapterLog.d("Liftoff placement \(adUnitId) isInLine=\(VungleAds.isInLine(adUnitId)) (banner placements are true)")

        let view = VungleBannerView(placementId: adUnitId, vungleAdSize: Self.adSize(size))
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
        AdvergicAdapterLog.d("Requesting Liftoff banner for placement \(adUnitId) at \(size)")
        view.load(nil)
    }

    func destroy() {
        bannerView?.delegate = nil
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func bannerAdDidLoad(_ bannerView: VungleBannerView) {
        AdvergicAdapterLog.d("Liftoff banner loaded: creativeId=\(bannerView.creativeId)")
        callbacks?.onLoaded()
    }

    func bannerAdDidFail(_ bannerView: VungleBannerView, withError: Error) {
        let message = Liftoff.message(withError)
        AdvergicAdapterLog.w("Liftoff banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func bannerAdDidTrackImpression(_ bannerView: VungleBannerView) {
        callbacks?.onRevenueUnavailable(Liftoff.noPrice)
    }

    func bannerAdDidClick(_ bannerView: VungleBannerView) {
        callbacks?.onClicked()
    }

    static func adSize(_ size: AdvergicAdSize) -> VungleAdSize {
        switch (size.width, size.height) {
        case (300, 250): return .VungleAdSizeMREC
        case (728, 90): return .VungleAdSizeLeaderboard
        case (320, 100): return .VungleAdSizeBannerShort
        default: return .VungleAdSizeBannerRegular
        }
    }
}

// MARK: Fullscreen

/// Interstitial and rewarded. App open goes through `VungleInterstitial` too: the dashboard
/// issues APPOPEN placements but the SDK has no app-open class.
final class LiftoffFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    VungleInterstitialDelegate, VungleRewardedDelegate {

    private var interstitial: VungleInterstitial?
    private var rewarded: VungleRewarded?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var format: AdvergicAdFormat = .interstitial

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.format = format
        clear()

        if Liftoff.isPlaceholder(adUnitId) {
            callbacks.onFailed("Liftoff \(format) placement is not set")
            return
        }
        AdvergicAdapterLog.d("Requesting Liftoff \(format) for placement \(adUnitId)")

        switch format {
        case .interstitial, .appOpen:
            let ad = VungleInterstitial(placementId: adUnitId)
            ad.delegate = self
            interstitial = ad
            ad.load(nil)
        case .rewarded:
            let ad = VungleRewarded(placementId: adUnitId)
            ad.delegate = self
            rewarded = ad
            ad.load(nil)
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial, interstitial.canPlayAd() { interstitial.present(with: viewController) }
        else if let rewarded, rewarded.canPlayAd() { rewarded.present(with: viewController) }
        else { AdvergicAdapterLog.w("Liftoff show called with no playable ad") }
    }

    func destroy() {
        clear()
        callbacks = nil
    }

    private func clear() {
        interstitial?.delegate = nil
        rewarded?.delegate = nil
        interstitial = nil
        rewarded = nil
    }

    private func loaded() {
        AdvergicAdapterLog.d("Liftoff \(format) loaded")
        callbacks?.onLoaded()
    }

    private func failed(_ error: Error, stage: String) {
        let message = Liftoff.message(error, stage: stage)
        AdvergicAdapterLog.w("Liftoff \(format) failed to \(stage): \(message)")
        if stage == "play" { clear() }
        callbacks?.onFailed(message)
    }

    private func closed() {
        clear()
        callbacks?.onDismissed()
    }

    func interstitialAdDidLoad(_ interstitial: VungleInterstitial) { loaded() }
    func interstitialAdDidFailToLoad(_ interstitial: VungleInterstitial, withError: Error) { failed(withError, stage: "load") }
    func interstitialAdDidFailToPresent(_ interstitial: VungleInterstitial, withError: Error) { failed(withError, stage: "play") }
    func interstitialAdDidPresent(_ interstitial: VungleInterstitial) { callbacks?.onShown() }
    func interstitialAdDidTrackImpression(_ interstitial: VungleInterstitial) { callbacks?.onRevenueUnavailable(Liftoff.noPrice) }
    func interstitialAdDidClick(_ interstitial: VungleInterstitial) { callbacks?.onClicked() }
    func interstitialAdDidClose(_ interstitial: VungleInterstitial) { closed() }

    func rewardedAdDidLoad(_ rewarded: VungleRewarded) { loaded() }
    func rewardedAdDidFailToLoad(_ rewarded: VungleRewarded, withError: Error) { failed(withError, stage: "load") }
    func rewardedAdDidFailToPresent(_ rewarded: VungleRewarded, withError: Error) { failed(withError, stage: "play") }
    func rewardedAdDidPresent(_ rewarded: VungleRewarded) { callbacks?.onShown() }
    func rewardedAdDidTrackImpression(_ rewarded: VungleRewarded) { callbacks?.onRevenueUnavailable(Liftoff.noPrice) }
    func rewardedAdDidClick(_ rewarded: VungleRewarded) { callbacks?.onClicked() }
    func rewardedAdDidClose(_ rewarded: VungleRewarded) { closed() }
    /// Liftoff's reward carries no amount or type.
    func rewardedAdDidRewardUser(_ rewarded: VungleRewarded) { callbacks?.onRewardEarned(0, "liftoff") }
}

// MARK: Native

/// Liftoff hands back its own media view to place inside the layout, then registers the whole
/// view for interaction.
final class LiftoffNativeAdapter: NSObject, AdvergicNativeAdapter, VungleNativeDelegate {

    private var nativeAd: VungleNative?
    private var template: AdvergicNativeTemplateView?
    private weak var container: UIView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        guard nativeAd == nil else { return }
        self.container = container
        self.callbacks = callbacks

        if Liftoff.isPlaceholder(adUnitId) {
            callbacks.onFailed("Liftoff native placement id is not set")
            return
        }
        let ad = VungleNative(placementId: adUnitId)
        ad.delegate = self
        nativeAd = ad
        AdvergicAdapterLog.d("Requesting Liftoff native for placement \(adUnitId)")
        ad.load(nil)
    }

    func destroy() {
        nativeAd?.unregisterView()
        nativeAd?.delegate = nil
        nativeAd = nil
        template?.removeFromSuperview()
        template = nil
        callbacks = nil
    }

    func nativeAdDidLoad(_ native: VungleNative) {
        guard let container else { return }
        let template = AdvergicNativeTemplateView()
        template.bind(headline: native.title, advertiser: native.sponsoredText, body: native.bodyText,
                      callToAction: native.callToAction, icon: native.iconImage)
        let media = MediaView()
        template.setMedia(media)
        AdvergicNativeTemplateView.pin(template, in: container)
        self.template = template

        native.registerViewForInteraction(
            view: template,
            mediaView: media,
            iconImageView: template.iconView,
            viewController: container.advergicViewController ?? UIView.advergicTopViewController
        )
        callbacks?.onLoaded()
    }

    func nativeAdDidFailToLoad(_ native: VungleNative, withError: Error) {
        let message = Liftoff.message(withError)
        AdvergicAdapterLog.w("Liftoff native failed: \(message)")
        callbacks?.onFailed(message)
    }

    func nativeAdDidTrackImpression(_ native: VungleNative) {
        callbacks?.onRevenueUnavailable(Liftoff.noPrice)
    }

    func nativeAdDidClick(_ native: VungleNative) {
        callbacks?.onClicked()
    }
}
#endif
