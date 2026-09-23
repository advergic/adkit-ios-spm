#if canImport(UIKit) && canImport(MTGSDK)
import Foundation
import MTGSDK
import MTGSDKBanner
import MTGSDKNewInterstitial
import MTGSDKReward
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Mintegral. A demand source that discloses no price. The only network needing two credentials
/// (app id and app key) and two ids per ad (placement and unit).
@objc(AdvergicMintegralAdapter)
final class MintegralAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .mintegral

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        MintegralInitializer(
            appId: setup.credential("app_id", fallback: setup.config.mintegralAppId),
            appKey: setup.credential("app_key", fallback: setup.config.mintegralAppKey)
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { MintegralBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { MintegralFullscreenAdapter() }

    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .mintegral, reason: .notIntegrated)
    }
}

/// The config carries one `adUnitId` per demand entry, so Mintegral's pair travels in it as
/// `placementId/unitId`. No separator means the unit id alone, with a blank placement.
struct MintegralIds: Equatable {
    let placementId: String
    let unitId: String

    init(_ adUnitId: String) {
        guard let slash = adUnitId.firstIndex(of: "/"), slash != adUnitId.startIndex else {
            placementId = ""
            unitId = adUnitId.trimmingCharacters(in: .whitespaces)
            return
        }
        placementId = String(adUnitId[..<slash]).trimmingCharacters(in: .whitespaces)
        unitId = String(adUnitId[adUnitId.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
    }

    var isPlaceholder: Bool { unitId.isEmpty || unitId.hasPrefix("REPLACE_WITH") }
}

enum MintegralSupport {
    static let noPrice = "Mintegral discloses no price to the SDK"

    static func message(_ error: Error?) -> String {
        guard let nsError = error as NSError? else { return "no ad and no error" }
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }
}

final class MintegralInitializer: AdvergicBaseInitializer {

    private let appId: String
    private let appKey: String

    init(appId: String, appKey: String) {
        self.appId = appId
        self.appKey = appKey
        super.init(networkName: AdvergicAdNetwork.mintegral.name)
    }

    override func start() {
        if isPlaceholder(appId) {
            markUnavailable(missingCredential("app id"))
            return
        }
        if isPlaceholder(appKey) {
            markUnavailable(missingCredential("app key"))
            return
        }
        AdvergicAdapterLog.d("Starting Mintegral \(MTGSDK.sdkVersion()) with app id \(appId)")
        MTGSDK.sharedInstance().initialize(withAppID: appId, apiKey: appKey) { [weak self] success, error in
            if success {
                self?.markReady()
            } else {
                self?.markUnavailable("Mintegral init failed: \(MintegralSupport.message(error))")
            }
        }
    }
}

// MARK: Banner

final class MintegralBannerAdapter: NSObject, AdvergicBannerAdapter, MTGBannerAdViewDelegate {

    private var bannerView: MTGBannerAdView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks
        let ids = MintegralIds(adUnitId)
        if ids.isPlaceholder {
            callbacks.onFailed("Mintegral banner unit id is not set")
            return
        }
        let view = MTGBannerAdView(
            bannerAdViewWithAdSize: CGSize(width: size.width, height: size.height),
            placementId: ids.placementId,
            unitId: ids.unitId,
            rootViewController: container.advergicViewController ?? UIView.advergicTopViewController
        )
        view.delegate = self
        // The chain decides when to ask again.
        view.autoRefreshTime = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        bannerView = view
        AdvergicAdapterLog.d("Requesting Mintegral banner for \(ids.placementId)/\(ids.unitId) at \(size)")
        view.loadBannerAd()
    }

    func destroy() {
        bannerView?.delegate = nil
        bannerView?.destroy()
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func adViewLoadSuccess(_ adView: MTGBannerAdView) {
        callbacks?.onLoaded()
    }

    func adViewLoadFailedWithError(_ error: Error, adView: MTGBannerAdView) {
        let message = MintegralSupport.message(error)
        AdvergicAdapterLog.w("Mintegral banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func adViewWillLogImpression(_ adView: MTGBannerAdView) {
        callbacks?.onRevenueUnavailable(MintegralSupport.noPrice)
    }

    func adViewDidClicked(_ adView: MTGBannerAdView) {
        callbacks?.onClicked()
    }

    func adViewWillLeaveApplication(_ adView: MTGBannerAdView) {}
    func adViewWillOpenFullScreen(_ adView: MTGBannerAdView) {}
    func adViewCloseFullScreen(_ adView: MTGBannerAdView) {}
    func adViewClosed(_ adView: MTGBannerAdView) {}
}

// MARK: Fullscreen

/// Interstitial through the "new interstitial" manager, rewarded through the rewarded-video
/// manager. Mintegral has no app-open format in this SDK build.
final class MintegralFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    MTGNewInterstitialAdDelegate, MTGRewardAdLoadDelegate, MTGRewardAdShowDelegate {

    private var interstitial: MTGNewInterstitialAdManager?
    private var rewardedIds: MintegralIds?
    private var callbacks: AdvergicFullscreenCallbacks?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        interstitial = nil
        rewardedIds = nil
        if format == .appOpen {
            callbacks.onFailed("MINTEGRAL has no app-open format")
            return
        }
        let ids = MintegralIds(adUnitId)
        if ids.isPlaceholder {
            callbacks.onFailed("Mintegral \(format) unit id is not set")
            return
        }
        AdvergicAdapterLog.d("Requesting Mintegral \(format) for \(ids.placementId)/\(ids.unitId)")
        if format == .rewarded {
            rewardedIds = ids
            MTGRewardAdManager.sharedInstance().loadVideo(withPlacementId: ids.placementId, unitId: ids.unitId, delegate: self)
        } else {
            let manager = MTGNewInterstitialAdManager(placementId: ids.placementId, unitId: ids.unitId, delegate: self)
            interstitial = manager
            manager.loadAd()
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial, interstitial.isAdReady() {
            interstitial.show(from: viewController)
        } else if let ids = rewardedIds,
                  MTGRewardAdManager.sharedInstance().isVideoReadyToPlay(withPlacementId: ids.placementId, unitId: ids.unitId) {
            MTGRewardAdManager.sharedInstance().showVideo(withPlacementId: ids.placementId, unitId: ids.unitId,
                                                          withRewardId: nil, userId: nil, delegate: self,
                                                          viewController: viewController)
        } else {
            AdvergicAdapterLog.w("Mintegral show called with no ready ad")
        }
    }

    func destroy() {
        interstitial = nil
        rewardedIds = nil
        callbacks = nil
    }

    private func failed(_ error: Error) {
        let message = MintegralSupport.message(error)
        AdvergicAdapterLog.w("Mintegral fullscreen failed: \(message)")
        callbacks?.onFailed(message)
    }

    private func shown() {
        callbacks?.onShown()
        callbacks?.onRevenueUnavailable(MintegralSupport.noPrice)
    }

    private func closed() {
        interstitial = nil
        rewardedIds = nil
        callbacks?.onDismissed()
    }

    // Interstitial — ready once the creative's resources are cached, not at campaign load.
    func newInterstitialAdResourceLoadSuccess(_ adManager: MTGNewInterstitialAdManager) { callbacks?.onLoaded() }
    func newInterstitialAdLoadFail(_ error: Error, adManager: MTGNewInterstitialAdManager) { failed(error) }
    func newInterstitialAdShowSuccess(_ adManager: MTGNewInterstitialAdManager) { shown() }
    func newInterstitialAdShowFail(_ error: Error, adManager: MTGNewInterstitialAdManager) {
        callbacks?.onFailed("show failed: \(MintegralSupport.message(error))")
    }
    func newInterstitialAdClicked(_ adManager: MTGNewInterstitialAdManager) { callbacks?.onClicked() }
    func newInterstitialAdDidClosed(_ adManager: MTGNewInterstitialAdManager) { closed() }

    // Rewarded
    func onVideoAdLoadSuccess(_ placementId: String?, unitId: String?) { callbacks?.onLoaded() }
    func onVideoAdLoadFailed(_ placementId: String?, unitId: String?, error: Error) { failed(error) }
    func onVideoAdShowSuccess(_ placementId: String?, unitId: String?) { shown() }
    func onVideoAdShowFailed(_ placementId: String?, unitId: String?, withError error: Error) {
        callbacks?.onFailed("show failed: \(MintegralSupport.message(error))")
    }
    func onVideoAdClicked(_ placementId: String?, unitId: String?) { callbacks?.onClicked() }
    func onVideoAdDismissed(_ placementId: String?, unitId: String?, withConverted converted: Bool,
                            withRewardInfo rewardInfo: MTGRewardAdInfo?) {
        // `converted` is Mintegral's "watched enough to earn it".
        if converted {
            callbacks?.onRewardEarned(rewardInfo?.rewardAmount ?? 0,
                                      rewardInfo?.rewardName.isEmpty == false ? rewardInfo!.rewardName : "mintegral")
        }
    }
    func onVideoAdDidClosed(_ placementId: String?, unitId: String?) { closed() }
}
#endif
