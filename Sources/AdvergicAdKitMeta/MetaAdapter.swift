#if canImport(UIKit) && canImport(FBAudienceNetwork)
import FBAudienceNetwork
import Foundation
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Meta Audience Network. Needs no app-level key — the placement id (`<appId>_<placementId>`)
/// carries the app id. A plain fill discloses no price; a slot that won an auction loads the
/// winning payload and reports the cleared price.
@objc(AdvergicMetaAdapter)
final class MetaAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .meta

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        MetaInitializer(
            testDeviceHashes: setup.testDevices(fallback: MetaDefaults.testDeviceHashes),
            testMode: setup.testMode(fallback: setup.config.metaTestMode),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { MetaBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { MetaFullscreenAdapter() }
    func makeNativeAdapter() -> AdvergicNativeAdapter { MetaNativeAdapter() }

    /// Generated locally; short-lived, so fetched per request.
    func bidderToken() async -> String? {
        let token = FBAdSettings.bidderToken
        return token.isEmpty ? nil : token
    }
}

enum MetaDefaults {
    /// Mirrors `Constants.metaTestDeviceHashes` in the core (not visible across modules).
    static let testDeviceHashes = ["b602d594afd2b0b327e07a06f36ca6a7e42546d0"]

    static let noPrice = "Meta discloses no price outside bidding"

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    /// The auction already cleared, so this is the exact amount the impression paid — hence
    /// precision `auction`, not an estimate.
    static func revenue(_ bid: AdvergicResolvedBid, placementId: String) -> AdvergicAdRevenue {
        AdvergicAdRevenue(
            amount: bid.price,
            currencyCode: bid.currency,
            amountUsd: bid.currency.uppercased() == "USD" ? bid.price : nil,
            precision: "auction",
            network: "meta",
            adUnitId: placementId
        )
    }
}

final class MetaInitializer: AdvergicBaseInitializer {

    private let testDeviceHashes: [String]
    private let testMode: Bool
    private let verboseLogging: Bool

    init(testDeviceHashes: [String], testMode: Bool, verboseLogging: Bool) {
        self.testDeviceHashes = testDeviceHashes
        self.testMode = testMode
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.meta.name)
    }

    override func start() {
        // Meta mints a new test hash per install, so a hard-coded list goes stale on reinstall
        // and an unlisted device answers with a bare "No fill". iOS has no test-mode switch;
        // registering this device's own current hash is the equivalent.
        if testMode {
            FBAdSettings.addTestDevice(FBAdSettings.testDeviceHash())
            AdvergicAdapterLog.d("Meta test mode on — this device (\(FBAdSettings.testDeviceHash())) only gets test ads")
        }
        if !testDeviceHashes.isEmpty {
            FBAdSettings.addTestDevices(testDeviceHashes)
        }
        if verboseLogging {
            FBAdSettings.setLogLevel(.log)
        }
        FBAudienceNetworkAds.initialize(with: nil) { [weak self] results in
            if results.isSuccess {
                self?.markReady()
            } else {
                self?.markUnavailable("Meta init failed: \(results.message)")
            }
        }
    }
}

// MARK: Banner

final class MetaBannerAdapter: NSObject, AdvergicBannerAdapter, FBAdViewDelegate {

    private var adView: FBAdView?
    private var callbacks: AdvergicBannerCallbacks?
    private var placementId = ""
    private var bid: AdvergicResolvedBid?
    private var bidTask: Task<Void, Never>?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard adView == nil else { return }
        self.callbacks = callbacks
        placementId = adUnitId

        if let bid {
            // The chain's auction already cleared this slot.
            load(container: container, size: size, bid: bid)
        } else if let provider = AdvergicMetaBidding.provider {
            // A pinned slot never went through the chain's auction; run one here.
            bidTask = Task { @MainActor [weak self] in
                let token = FBAdSettings.bidderToken
                guard !token.isEmpty else {
                    self?.callbacks?.onFailed("Meta bidder token unavailable — cannot run an auction")
                    return
                }
                do {
                    let won = try await provider.fetchMetaBid(placementId: adUnitId, bidderToken: token, size: size)
                    guard let self, !Task.isCancelled else { return }
                    self.load(container: container, size: size,
                              bid: AdvergicResolvedBid(payload: won.payload, price: won.price, currency: won.currency))
                } catch {
                    AdvergicAdapterLog.w("Meta bid failed: \(error.localizedDescription)")
                    self?.callbacks?.onFailed("Meta bid failed: \(error.localizedDescription)")
                }
            }
        } else {
            load(container: container, size: size, bid: nil)
        }
    }

    private func load(container: UIView, size: AdvergicAdSize, bid: AdvergicResolvedBid?) {
        self.bid = bid
        let view = FBAdView(
            placementID: placementId,
            adSize: Self.adSize(size),
            rootViewController: container.advergicViewController ?? UIView.advergicTopViewController
        )
        view.delegate = self
        view.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        adView = view

        if let bid {
            AdvergicAdapterLog.d("Loading Meta banner for \(placementId) with bid \(bid.price) \(bid.currency)")
            view.loadAd(withBidPayload: bid.payload)
        } else {
            AdvergicAdapterLog.d("Requesting Meta banner for \(placementId) at \(size)")
            view.loadAd()
        }
    }

    func destroy() {
        bidTask?.cancel()
        adView?.delegate = nil
        adView?.removeFromSuperview()
        adView = nil
        callbacks = nil
    }

    func adViewDidLoad(_ adView: FBAdView) {
        AdvergicAdapterLog.d("Meta banner loaded")
        callbacks?.onLoaded()
        if let bid {
            callbacks?.onRevenue(MetaDefaults.revenue(bid, placementId: placementId))
        } else {
            callbacks?.onRevenueUnavailable(MetaDefaults.noPrice)
        }
    }

    func adView(_ adView: FBAdView, didFailWithError error: Error) {
        let message = MetaDefaults.message(error)
        AdvergicAdapterLog.w("Meta banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func adViewDidClick(_ adView: FBAdView) {
        callbacks?.onClicked()
    }

    /// Meta ships fixed banner heights; anything else maps to the closest one.
    static func adSize(_ size: AdvergicAdSize) -> FBAdSize {
        switch size.height {
        case 250: return kFBAdSizeHeight250Rectangle
        case 90: return kFBAdSizeHeight90Banner
        default: return kFBAdSizeHeight50Banner
        }
    }
}

// MARK: Fullscreen

/// Interstitial, and rewarded as Meta's rewarded *video* (what a "Rewarded Video" placement
/// serves). Meta has no app-open format.
final class MetaFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    FBInterstitialAdDelegate, FBRewardedVideoAdDelegate {

    private var interstitial: FBInterstitialAd?
    private var rewarded: FBRewardedVideoAd?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var placementId = ""
    private var bid: AdvergicResolvedBid?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        placementId = adUnitId
        self.bid = bid
        clear()

        switch format {
        case .interstitial:
            let ad = FBInterstitialAd(placementID: adUnitId)
            ad.delegate = self
            interstitial = ad
            if let bid { ad.load(withBidPayload: bid.payload) } else { ad.load() }
        case .rewarded:
            let ad = FBRewardedVideoAd(placementID: adUnitId)
            ad.delegate = self
            rewarded = ad
            if let bid { ad.load(withBidPayload: bid.payload) } else { ad.load() }
        case .appOpen:
            callbacks.onFailed("Meta has no app-open format")
            return
        }
        AdvergicAdapterLog.d("Requesting Meta \(format) for \(adUnitId)")
    }

    func show(from viewController: UIViewController) {
        if let interstitial, interstitial.isAdValid {
            interstitial.show(fromRootViewController: viewController)
        } else if let rewarded, rewarded.isAdValid {
            rewarded.show(fromRootViewController: viewController)
        } else {
            AdvergicAdapterLog.w("Meta show called with no valid cached ad")
        }
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

    private func failed(_ error: Error) {
        let message = MetaDefaults.message(error)
        AdvergicAdapterLog.w("Meta fullscreen failed: \(message)")
        callbacks?.onFailed(message)
    }

    private func impression() {
        callbacks?.onShown()
        if let bid {
            callbacks?.onRevenue(MetaDefaults.revenue(bid, placementId: placementId))
        } else {
            callbacks?.onRevenueUnavailable(MetaDefaults.noPrice)
        }
    }

    private func closed() {
        clear()
        callbacks?.onDismissed()
    }

    func interstitialAdDidLoad(_ interstitialAd: FBInterstitialAd) { callbacks?.onLoaded() }
    func interstitialAd(_ interstitialAd: FBInterstitialAd, didFailWithError error: Error) { failed(error) }
    func interstitialAdWillLogImpression(_ interstitialAd: FBInterstitialAd) { impression() }
    func interstitialAdDidClick(_ interstitialAd: FBInterstitialAd) { callbacks?.onClicked() }
    func interstitialAdDidClose(_ interstitialAd: FBInterstitialAd) { closed() }

    func rewardedVideoAdDidLoad(_ rewardedVideoAd: FBRewardedVideoAd) { callbacks?.onLoaded() }
    func rewardedVideoAd(_ rewardedVideoAd: FBRewardedVideoAd, didFailWithError error: Error) { failed(error) }
    func rewardedVideoAdWillLogImpression(_ rewardedVideoAd: FBRewardedVideoAd) { impression() }
    func rewardedVideoAdDidClick(_ rewardedVideoAd: FBRewardedVideoAd) { callbacks?.onClicked() }
    func rewardedVideoAdDidClose(_ rewardedVideoAd: FBRewardedVideoAd) { closed() }
    /// Meta's reward carries no amount or type of its own.
    func rewardedVideoAdVideoComplete(_ rewardedVideoAd: FBRewardedVideoAd) {
        callbacks?.onRewardEarned(0, "meta")
    }
}

// MARK: Native

/// Meta ships a template renderer, so unlike AdMob and Yandex no layout is bound by hand.
final class MetaNativeAdapter: NSObject, AdvergicNativeAdapter, FBNativeAdDelegate {

    private var nativeAd: FBNativeAd?
    private weak var container: UIView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        guard nativeAd == nil else { return }
        self.container = container
        self.callbacks = callbacks
        let ad = FBNativeAd(placementID: adUnitId)
        ad.delegate = self
        nativeAd = ad
        AdvergicAdapterLog.d("Requesting Meta native for \(adUnitId)")
        ad.loadAd()
    }

    func destroy() {
        nativeAd?.delegate = nil
        nativeAd?.unregisterView()
        nativeAd = nil
        container?.subviews.forEach { $0.removeFromSuperview() }
        callbacks = nil
    }

    func nativeAdDidLoad(_ nativeAd: FBNativeAd) {
        guard let container else { return }
        let view = FBNativeAdView(nativeAd: nativeAd, with: .genericHeight300)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 300),
        ])
        callbacks?.onLoaded()
    }

    func nativeAd(_ nativeAd: FBNativeAd, didFailWithError error: Error) {
        let message = MetaDefaults.message(error)
        AdvergicAdapterLog.w("Meta native failed: \(message)")
        callbacks?.onFailed(message)
    }

    func nativeAdWillLogImpression(_ nativeAd: FBNativeAd) {
        callbacks?.onRevenueUnavailable(MetaDefaults.noPrice)
    }

    func nativeAdDidClick(_ nativeAd: FBNativeAd) {
        callbacks?.onClicked()
    }
}
#endif
