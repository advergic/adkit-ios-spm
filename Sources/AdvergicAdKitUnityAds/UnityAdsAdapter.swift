#if canImport(UIKit) && canImport(UnityAds)
import Foundation
import UIKit
import UnityAds
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Unity Ads. A demand source that discloses no price. The game id is issued per platform —
/// the Android one initializes cleanly on iOS and then never fills. No app-open, no native.
@objc(AdvergicUnityAdsAdapter)
final class UnityAdsAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .unityAds

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        UnityAdsInitializer(
            gameId: setup.credential("game_id", fallback: setup.config.unityGameId),
            testMode: setup.testMode(fallback: setup.config.unityTestMode),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { UnityAdsBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { UnityAdsFullscreenAdapter() }

    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .unityAds, reason: .unsupported)
    }
}

enum UnityAdsSupport {
    static let noPrice = "Unity Ads discloses no price to the SDK"

    static func isPlaceholder(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespaces).isEmpty || id.hasPrefix("REPLACE_WITH")
    }
}

final class UnityAdsInitializer: AdvergicBaseInitializer, UnityAdsInitializationDelegate {

    private let gameId: String
    private let testMode: Bool
    private let verboseLogging: Bool

    init(gameId: String, testMode: Bool, verboseLogging: Bool) {
        self.gameId = gameId
        self.testMode = testMode
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.unityAds.name)
    }

    override func start() {
        if isPlaceholder(gameId) {
            markUnavailable(missingCredential("game id"))
            return
        }
        UnityAds.setDebugMode(verboseLogging)
        AdvergicAdapterLog.d("Starting Unity Ads \(UnityAds.getVersion()) with game id \(gameId), testMode=\(testMode)")
        UnityAds.initialize(gameId, testMode: testMode, initializationDelegate: self)
    }

    func initializationComplete() {
        markReady()
    }

    func initializationFailed(_ error: UnityAdsInitializationError, withMessage message: String) {
        markUnavailable("Unity Ads init failed: \(message) (code=\(error.rawValue))")
    }
}

// MARK: Banner

/// Unity sizes a banner from the box it is given, so one placement serves every size.
final class UnityAdsBannerAdapter: NSObject, AdvergicBannerAdapter, UADSBannerViewDelegate {

    private var bannerView: UADSBannerView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks
        if UnityAdsSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("Unity Ads banner placement is not set")
            return
        }
        let view = UADSBannerView(placementId: adUnitId, size: CGSize(width: size.width, height: size.height))
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
        AdvergicAdapterLog.d("Requesting Unity Ads banner for \(adUnitId) at \(size)")
        view.load()
    }

    func destroy() {
        bannerView?.delegate = nil
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func bannerViewDidLoad(_ bannerView: UADSBannerView) {
        callbacks?.onLoaded()
    }

    func bannerViewDidShow(_ bannerView: UADSBannerView) {
        callbacks?.onRevenueUnavailable(UnityAdsSupport.noPrice)
    }

    func bannerViewDidClick(_ bannerView: UADSBannerView) {
        callbacks?.onClicked()
    }

    func bannerViewDidError(_ bannerView: UADSBannerView, error: UADSBannerError) {
        let message = "\(error.localizedDescription) (code=\(error.code))"
        AdvergicAdapterLog.w("Unity Ads banner failed: \(message)")
        callbacks?.onFailed(message)
    }
}

// MARK: Fullscreen

/// Interstitial and rewarded share one API — the placement decides the format. A rewarded
/// placement grants its reward when the show completes rather than being skipped.
final class UnityAdsFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    UnityAdsLoadDelegate, UnityAdsShowDelegate {

    private var placementId: String?
    private var loaded = false
    private var format: AdvergicAdFormat = .interstitial
    private var callbacks: AdvergicFullscreenCallbacks?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.format = format
        loaded = false
        placementId = nil
        if format == .appOpen {
            callbacks.onFailed("UNITY_ADS has no app-open format")
            return
        }
        if UnityAdsSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("Unity Ads \(format) placement is not set")
            return
        }
        placementId = adUnitId
        AdvergicAdapterLog.d("Requesting Unity Ads \(format) for \(adUnitId)")
        UnityAds.load(adUnitId, loadDelegate: self)
    }

    func show(from viewController: UIViewController) {
        guard let placementId, loaded else {
            AdvergicAdapterLog.w("Unity Ads show called with no loaded ad")
            return
        }
        UnityAds.show(viewController, placementId: placementId, showDelegate: self)
    }

    func destroy() {
        placementId = nil
        loaded = false
        callbacks = nil
    }

    func unityAdsAdLoaded(_ placementId: String) {
        guard placementId == self.placementId else { return }
        loaded = true
        callbacks?.onLoaded()
    }

    func unityAdsAdFailed(toLoad placementId: String, withError error: UnityAdsLoadError, withMessage message: String) {
        guard placementId == self.placementId else { return }
        let text = "\(message) (code=\(error.rawValue))"
        AdvergicAdapterLog.w("Unity Ads \(format) failed: \(text)")
        callbacks?.onFailed(text)
    }

    func unityAdsShowStart(_ placementId: String) {
        callbacks?.onShown()
        callbacks?.onRevenueUnavailable(UnityAdsSupport.noPrice)
    }

    func unityAdsShowClick(_ placementId: String) {
        callbacks?.onClicked()
    }

    func unityAdsShowComplete(_ placementId: String, withFinish state: UnityAdsShowCompletionState) {
        loaded = false
        if format == .rewarded && state == .showCompletionStateCompleted {
            // Unity's reward carries no amount or type of its own.
            callbacks?.onRewardEarned(0, "unity")
        }
        callbacks?.onDismissed()
    }

    func unityAdsShowFailed(_ placementId: String, withError error: UnityAdsShowError, withMessage message: String) {
        loaded = false
        callbacks?.onFailed("show failed: \(message) (code=\(error.rawValue))")
    }
}
#endif
