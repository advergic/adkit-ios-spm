#if canImport(UIKit) && canImport(InMobiSDK)
import Foundation
import InMobiSDK
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// InMobi, through its own SDK. A demand source that *does* disclose a price: each fill carries
/// the winning bid on `IMAdMetaInfo`. Placements are numeric and issued per ad size and per app.
@objc(AdvergicInMobiAdapter)
final class InMobiAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .inMobi

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        InMobiInitializer(
            accountId: setup.credential("account_id", fallback: setup.config.inMobiAccountId),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { InMobiBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { InMobiFullscreenAdapter() }

    /// Native registration isn't wired on Android either; kept in step.
    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .inMobi, reason: .notIntegrated)
    }
}

enum InMobi {

    /// Numeric, like Android's `Long` placement ids. Nil for a placeholder or anything else.
    static func placementId(_ raw: String) -> Int64? {
        Int64(raw.trimmingCharacters(in: .whitespaces))
    }

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    /// A zero bid is InMobi declining to disclose one — house or backfill demand reports it —
    /// which is "no price", not "paid nothing".
    static func report(_ info: IMAdMetaInfo, adUnitId: String,
                       onRevenue: (AdvergicAdRevenue) -> Void, onUnavailable: (String) -> Void) {
        let bid = info.getBid()
        AdvergicAdapterLog.d("InMobi meta raw: bid=\(bid), creativeID=\(info.creativeID ?? "nil"), bidInfo=\(info.bidInfo)")
        guard bid > 0 else {
            onUnavailable("InMobi reported a zero bid for this fill")
            return
        }
        // InMobi quotes the bid in USD.
        onRevenue(AdvergicAdRevenue(amount: bid, currencyCode: "USD", amountUsd: bid,
                                    precision: "bid", network: "inmobi", adUnitId: adUnitId))
    }
}

final class InMobiInitializer: AdvergicBaseInitializer {

    private let accountId: String
    private let verboseLogging: Bool

    init(accountId: String, verboseLogging: Bool) {
        self.accountId = accountId
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.inMobi.name)
    }

    override func start() {
        if isPlaceholder(accountId) {
            markUnavailable(missingCredential("account id"))
            return
        }
        IMSdk.setLogLevel(verboseLogging ? .debug : .error)
        AdvergicAdapterLog.d("Starting InMobi \(IMSdk.getVersion()) with account \(AdvergicAdapterLog.isEnabled ? accountId : "…")")
        IMSdk.initWithAccountID(accountId) { [weak self] error in
            if let error {
                self?.markUnavailable("InMobi init failed: \(InMobi.message(error))")
            } else {
                self?.markReady()
            }
        }
    }
}

// MARK: Banner

final class InMobiBannerAdapter: NSObject, AdvergicBannerAdapter, IMBannerDelegate {

    private var banner: IMBanner?
    private var callbacks: AdvergicBannerCallbacks?
    private var adUnitId = ""
    private var metaInfo: IMAdMetaInfo?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard banner == nil else { return }
        self.callbacks = callbacks
        self.adUnitId = adUnitId

        guard let placement = InMobi.placementId(adUnitId) else {
            callbacks.onFailed("InMobi placement id '\(adUnitId)' is not a numeric placement")
            return
        }
        // InMobi sizes the creative from the frame, so it must be the exact slot size.
        let view = IMBanner(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                            placementId: placement, delegate: self)
        view.shouldAutoRefresh(false)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        banner = view
        AdvergicAdapterLog.d("Requesting InMobi banner for placement \(placement) at \(size)")
        view.load()
    }

    func destroy() {
        banner?.delegate = nil
        banner?.cancel()
        banner?.removeFromSuperview()
        banner = nil
        callbacks = nil
    }

    func banner(_ banner: IMBanner, didReceiveWithMetaInfo info: IMAdMetaInfo) {
        metaInfo = info
    }

    func bannerDidFinishLoading(_ banner: IMBanner) {
        callbacks?.onLoaded()
        // The price arrives with the fill; reported once it has rendered.
        if let callbacks, let metaInfo {
            InMobi.report(metaInfo, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                          onUnavailable: callbacks.onRevenueUnavailable)
        } else {
            callbacks?.onRevenueUnavailable("InMobi sent no meta info for this fill")
        }
    }

    func banner(_ banner: IMBanner, didFailToLoadWithError error: IMRequestStatus) {
        failed(error)
    }

    func banner(_ banner: IMBanner, didFailToReceiveWithError error: IMRequestStatus) {
        failed(error)
    }

    func banner(_ banner: IMBanner, didInteractWithParams params: [String: Any]?) {
        callbacks?.onClicked()
    }

    private func failed(_ error: Error) {
        // The status code separates "nobody bid" from "wrong placement".
        let message = InMobi.message(error)
        AdvergicAdapterLog.w("InMobi banner failed: \(message)")
        callbacks?.onFailed(message)
    }
}

// MARK: Fullscreen

/// Interstitial and rewarded are the same class — the *placement* decides whether a reward
/// fires. InMobi has no app-open format.
final class InMobiFullscreenAdapter: NSObject, AdvergicFullscreenAdapter, IMInterstitialDelegate {

    private var interstitial: IMInterstitial?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var adUnitId = ""
    private var metaInfo: IMAdMetaInfo?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.adUnitId = adUnitId
        interstitial = nil

        if format == .appOpen {
            callbacks.onFailed("INMOBI has no app-open format")
            return
        }
        guard let placement = InMobi.placementId(adUnitId) else {
            callbacks.onFailed("InMobi \(format) placement id '\(adUnitId)' is not a numeric placement")
            return
        }
        let ad = IMInterstitial(placementId: placement, delegate: self)
        interstitial = ad
        AdvergicAdapterLog.d("Requesting InMobi \(format) for placement \(placement)")
        ad.load()
    }

    func show(from viewController: UIViewController) {
        guard let interstitial, interstitial.isReady() else {
            AdvergicAdapterLog.w("InMobi show called with no ready ad")
            return
        }
        interstitial.show(from: viewController)
    }

    func destroy() {
        interstitial?.delegate = nil
        interstitial?.cancel()
        interstitial = nil
        callbacks = nil
    }

    func interstitial(_ interstitial: IMInterstitial, didReceiveWithMetaInfo metaInfo: IMAdMetaInfo) {
        self.metaInfo = metaInfo
    }

    func interstitialDidFinishLoading(_ interstitial: IMInterstitial) {
        callbacks?.onLoaded()
    }

    func interstitial(_ interstitial: IMInterstitial, didFailToLoadWithError error: IMRequestStatus) {
        let message = InMobi.message(error)
        AdvergicAdapterLog.w("InMobi fullscreen failed: \(message)")
        callbacks?.onFailed(message)
    }

    func interstitialDidPresent(_ interstitial: IMInterstitial) {
        callbacks?.onShown()
        if let callbacks, let metaInfo {
            InMobi.report(metaInfo, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                          onUnavailable: callbacks.onRevenueUnavailable)
        }
    }

    func interstitial(_ interstitial: IMInterstitial, didFailToPresentWithError error: IMRequestStatus) {
        callbacks?.onFailed("show failed: \(InMobi.message(error))")
    }

    func interstitialDidDismiss(_ interstitial: IMInterstitial) {
        self.interstitial = nil
        callbacks?.onDismissed()
    }

    func interstitial(_ interstitial: IMInterstitial, didInteractWithParams params: [String: Any]?) {
        callbacks?.onClicked()
    }

    /// InMobi's rewards are a free-form dictionary; the first entry is taken as type → amount.
    func interstitial(_ interstitial: IMInterstitial, rewardActionCompletedWithRewards rewards: [String: Any]) {
        let first = rewards.first
        let amount = (first?.value as? NSNumber)?.intValue ?? Int("\(first?.value ?? 0)") ?? 0
        callbacks?.onRewardEarned(amount, first?.key ?? "inmobi")
    }
}
#endif
