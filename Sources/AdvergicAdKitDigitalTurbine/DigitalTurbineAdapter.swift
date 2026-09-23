#if canImport(UIKit) && canImport(FairBidSDK)
import FairBidSDK
import Foundation
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

// FairBid publishes no Swift package, so this module ships through the podspec's
// `AdvergicAdKit/DigitalTurbine` subspec only.

/// Digital Turbine, through its FairBid mediation SDK. A mediator: the price rides on the
/// impression data handed to each show callback, and it names its own currency rather than
/// assuming USD. No app-open, no native.
@objc(AdvergicDigitalTurbineAdapter)
final class DigitalTurbineAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .digitalTurbine

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        DigitalTurbineInitializer(
            appId: setup.credential("app_id", fallback: setup.config.digitalTurbineAppId),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { DigitalTurbineBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { DigitalTurbineFullscreenAdapter() }

    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .digitalTurbine, reason: .unsupported)
    }

    /// FairBid's test suite: per-network integration status.
    func showDebugPanel(from viewController: UIViewController) -> Bool {
        FairBid.presentTestSuite()
        return true
    }
}

enum DigitalTurbineSupport {

    static func message(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    static func isPlaceholder(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespaces).isEmpty || id.hasPrefix("REPLACE_WITH")
    }

    /// An undisclosed price is FairBid declining to say, not the impression paying zero.
    static func report(_ data: FYBImpressionData, placementId: String,
                       onRevenue: (AdvergicAdRevenue) -> Void, onUnavailable: (String) -> Void) {
        guard data.priceAccuracy != .undisclosed, let payout = data.netPayout?.doubleValue, payout > 0 else {
            onUnavailable("Digital Turbine disclosed no price for this fill (\(data.demandSource ?? "unknown"))")
            return
        }
        let currency = data.currency.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        onRevenue(AdvergicAdRevenue(
            amount: payout,
            currencyCode: currency,
            amountUsd: currency.uppercased() == "USD" ? payout : nil,
            precision: data.priceAccuracy == .programmatic ? "programmatic" : "predicted",
            network: data.demandSource.flatMap { $0.isEmpty ? nil : $0 } ?? "digitalturbine",
            adUnitId: placementId
        ))
    }
}

final class DigitalTurbineInitializer: AdvergicBaseInitializer {

    private let appId: String
    private let verboseLogging: Bool

    init(appId: String, verboseLogging: Bool) {
        self.appId = appId
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.digitalTurbine.name)
    }

    override func start() {
        if isPlaceholder(appId) {
            markUnavailable(missingCredential("app id"))
            return
        }
        let options = FYBStartOptions()
        options.logLevel = verboseLogging ? .verbose : .error
        // The chain decides when to request; FairBid's own auto-requesting would fill behind it.
        options.autoRequestingEnabled = false
        DigitalTurbineRouter.shared.install()
        AdvergicAdapterLog.d("Starting Digital Turbine FairBid \(FairBid.version()) with app id \(appId)")
        FairBid.start(withAppId: appId, options: options)
        // FairBid starts asynchronously but accepts requests immediately and queues them.
        markReady()
    }
}

/// FairBid's delegates are class-level and process-wide; this fans each callback out to the
/// adapter that owns the placement.
final class DigitalTurbineRouter: NSObject, FYBBannerDelegate, FYBInterstitialDelegate, FYBRewardedDelegate {

    static let shared = DigitalTurbineRouter()

    private var banners: [String: DigitalTurbineBannerAdapter] = [:]
    private var fullscreens: [String: DigitalTurbineFullscreenAdapter] = [:]

    func install() {
        FYBBanner.delegate = self
        FYBInterstitial.delegate = self
        FYBRewarded.delegate = self
    }

    func register(_ adapter: DigitalTurbineBannerAdapter, for placement: String) { banners[placement] = adapter }
    func register(_ adapter: DigitalTurbineFullscreenAdapter, for placement: String) { fullscreens[placement] = adapter }
    func unregisterBanner(_ placement: String) { banners[placement] = nil }
    func unregisterFullscreen(_ placement: String) { fullscreens[placement] = nil }

    // Banner
    func bannerDidLoad(_ banner: FYBBannerAdView, impressionData: FYBImpressionData) {
        banners[banner.options.placementId]?.loaded()
    }
    func bannerDidFail(toLoad placementId: String, withError error: Error) {
        banners[placementId]?.failed(error)
    }
    func bannerDidShow(_ banner: FYBBannerAdView, impressionData: FYBImpressionData) {
        banners[banner.options.placementId]?.impression(impressionData)
    }
    func bannerDidClick(_ banner: FYBBannerAdView) {
        banners[banner.options.placementId]?.clicked()
    }

    // Interstitial
    func interstitialIsAvailable(_ placementId: String) { fullscreens[placementId]?.available() }
    func interstitialIsUnavailable(_ placementId: String) { fullscreens[placementId]?.unavailable() }
    func interstitialDidShow(_ placementId: String, impressionData: FYBImpressionData) { fullscreens[placementId]?.shown(impressionData) }
    func interstitialDidFail(toShow placementId: String, withError error: Error, impressionData: FYBImpressionData) {
        fullscreens[placementId]?.failedToShow(error)
    }
    func interstitialDidClick(_ placementId: String) { fullscreens[placementId]?.clicked() }
    func interstitialDidDismiss(_ placementId: String) { fullscreens[placementId]?.dismissed() }

    // Rewarded
    func rewardedIsAvailable(_ placementId: String) { fullscreens[placementId]?.available() }
    func rewardedIsUnavailable(_ placementId: String) { fullscreens[placementId]?.unavailable() }
    func rewardedDidShow(_ placementId: String, impressionData: FYBImpressionData) { fullscreens[placementId]?.shown(impressionData) }
    func rewardedDidFail(toShow placementId: String, withError error: Error, impressionData: FYBImpressionData) {
        fullscreens[placementId]?.failedToShow(error)
    }
    func rewardedDidClick(_ placementId: String) { fullscreens[placementId]?.clicked() }
    func rewardedDidDismiss(_ placementId: String) { fullscreens[placementId]?.dismissed() }
    func rewardedDidComplete(_ placementId: String, userRewarded: Bool) {
        if userRewarded { fullscreens[placementId]?.rewarded() }
    }
}

// MARK: Banner

final class DigitalTurbineBannerAdapter: NSObject, AdvergicBannerAdapter {

    private var placementId: String?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard placementId == nil else { return }
        self.callbacks = callbacks
        if DigitalTurbineSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("Digital Turbine banner placement is not set")
            return
        }
        placementId = adUnitId
        DigitalTurbineRouter.shared.register(self, for: adUnitId)
        let options = FYBBannerOptions(placementId: adUnitId)
        options.presentingViewController = container.advergicViewController ?? UIView.advergicTopViewController
        options.refreshMode = .manual
        AdvergicAdapterLog.d("Requesting Digital Turbine banner for \(adUnitId) at \(size)")
        FYBBanner.show(in: container, options: options)
    }

    func destroy() {
        if let placementId {
            FYBBanner.destroy(placementId)
            DigitalTurbineRouter.shared.unregisterBanner(placementId)
        }
        placementId = nil
        callbacks = nil
    }

    func loaded() { callbacks?.onLoaded() }

    func failed(_ error: Error) {
        let message = DigitalTurbineSupport.message(error)
        AdvergicAdapterLog.w("Digital Turbine banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func impression(_ data: FYBImpressionData) {
        guard let callbacks, let placementId else { return }
        DigitalTurbineSupport.report(data, placementId: placementId, onRevenue: callbacks.onRevenue,
                                     onUnavailable: callbacks.onRevenueUnavailable)
    }

    func clicked() { callbacks?.onClicked() }
}

// MARK: Fullscreen

final class DigitalTurbineFullscreenAdapter: NSObject, AdvergicFullscreenAdapter {

    private var placementId: String?
    private var format: AdvergicAdFormat = .interstitial
    private var callbacks: AdvergicFullscreenCallbacks?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.format = format
        if format == .appOpen {
            callbacks.onFailed("DIGITAL_TURBINE has no app-open format")
            return
        }
        if DigitalTurbineSupport.isPlaceholder(adUnitId) {
            callbacks.onFailed("Digital Turbine \(format) placement is not set")
            return
        }
        placementId = adUnitId
        DigitalTurbineRouter.shared.register(self, for: adUnitId)
        AdvergicAdapterLog.d("Requesting Digital Turbine \(format) for \(adUnitId)")
        if format == .rewarded {
            FYBRewarded.request(adUnitId)
        } else {
            FYBInterstitial.request(adUnitId)
        }
    }

    func show(from viewController: UIViewController) {
        guard let placementId else { return }
        let options = FYBShowOptions()
        options.viewController = viewController
        if format == .rewarded, FYBRewarded.isAvailable(placementId) {
            FYBRewarded.show(placementId, options: options)
        } else if format == .interstitial, FYBInterstitial.isAvailable(placementId) {
            FYBInterstitial.show(placementId, options: options)
        } else {
            AdvergicAdapterLog.w("Digital Turbine show called with no available ad")
        }
    }

    func destroy() {
        if let placementId { DigitalTurbineRouter.shared.unregisterFullscreen(placementId) }
        placementId = nil
        callbacks = nil
    }

    func available() { callbacks?.onLoaded() }
    func unavailable() { callbacks?.onFailed("Digital Turbine has no fill for \(placementId ?? "?")") }

    func shown(_ data: FYBImpressionData) {
        guard let callbacks, let placementId else { return }
        callbacks.onShown()
        DigitalTurbineSupport.report(data, placementId: placementId, onRevenue: callbacks.onRevenue,
                                     onUnavailable: callbacks.onRevenueUnavailable)
    }

    func failedToShow(_ error: Error) {
        callbacks?.onFailed("show failed: \(DigitalTurbineSupport.message(error))")
    }

    func clicked() { callbacks?.onClicked() }

    /// FairBid's reward carries no amount or type of its own.
    func rewarded() { callbacks?.onRewardEarned(0, "digitalturbine") }

    func dismissed() { callbacks?.onDismissed() }
}
#endif
