#if canImport(UIKit) && canImport(ChartboostMediationSDK)
import ChartboostCoreSDK
import ChartboostMediationSDK
import Foundation
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

// Chartboost Mediation ships only through CocoaPods, so this module is built by the
// `AdvergicAdKit/Chartboost` subspec and is absent from Package.swift.

/// Chartboost Mediation. A mediator: it prices whatever demand wins, and reports it on a
/// process-wide impression-level revenue (ILRD) notification. Mediation 5.x registers as a module
/// of Chartboost Core, so the app id goes to Core, not to Mediation.
@objc(AdvergicChartboostAdapter)
final class ChartboostAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .chartboost

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        ChartboostInitializer(
            appId: setup.credential("app_id", fallback: setup.config.chartboostAppId),
            testMode: setup.testMode(fallback: setup.config.chartboostTestMode),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { ChartboostBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { ChartboostFullscreenAdapter() }

    /// Chartboost Mediation has no native format at all.
    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .chartboost, reason: .unsupported)
    }
}

enum ChartboostSupport {

    static func message(_ error: Error?) -> String {
        guard let error = error as? ChartboostMediationError else {
            return error.map { "\($0.localizedDescription)" } ?? "no ad and no error"
        }
        // These are fixed classifications rather than the server's answer, so the code name is
        // what distinguishes one from another.
        return "\(error.chartboostMediationCode.name) \(error.localizedDescription) (code=\(error.code))"
    }

    /// Observes the ILRD notification for one placement. Mediation posts every impression to
    /// the same process-wide channel, so each slot filters on its own placement.
    static func observeRevenue(placement: String, onRevenue: @escaping (AdvergicAdRevenue) -> Void,
                               onUnavailable: @escaping (String) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .chartboostMediationDidReceiveILRD, object: nil, queue: .main
        ) { note in
            guard let data = note.object as? ImpressionData, data.placement == placement else { return }
            let info = data.jsonData
            AdvergicAdapterLog.d("Chartboost ILRD raw: \(info)")

            guard let amount = (info["ad_revenue"] as? NSNumber)?.doubleValue, amount > 0 else {
                onUnavailable("Chartboost disclosed no revenue for this fill")
                return
            }
            let currency = (info["currency_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
            onRevenue(AdvergicAdRevenue(
                amount: amount,
                currencyCode: currency,
                amountUsd: currency.uppercased() == "USD" ? amount : nil,
                precision: (info["precision"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "mediation",
                network: (info["network_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "chartboost",
                adUnitId: placement
            ))
        }
    }
}

final class ChartboostInitializer: AdvergicBaseInitializer, ModuleObserver {

    private let appId: String
    private let testMode: Bool
    private let verboseLogging: Bool

    init(appId: String, testMode: Bool, verboseLogging: Bool) {
        self.appId = appId
        self.testMode = testMode
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.chartboost.name)
    }

    override func start() {
        if isPlaceholder(appId) {
            markUnavailable(missingCredential("app id"))
            return
        }
        // Chartboost serves real demand only to apps live on a store; test mode is the only way
        // to exercise a setup before release. Never ship it true.
        ChartboostMediation.isTestModeEnabled = testMode
        if verboseLogging { ChartboostMediation.logLevel = .verbose }
        AdvergicAdapterLog.d("Starting Chartboost Mediation \(ChartboostMediation.sdkVersion) with app id \(appId), testMode=\(testMode)")
        ChartboostCore.initializeSDK(configuration: SDKConfiguration(chartboostAppID: appId), moduleObserver: self)
    }

    func onModuleInitializationCompleted(_ result: ModuleInitializationResult) {
        guard result.moduleID == ChartboostMediation.coreModuleID else { return }
        if let error = result.error {
            markUnavailable("Chartboost init failed: \(ChartboostSupport.message(error))")
        } else {
            markReady()
        }
    }
}

// MARK: Banner

final class ChartboostBannerAdapter: NSObject, AdvergicBannerAdapter, BannerAdViewDelegate {

    private var bannerView: BannerAdView?
    private var callbacks: AdvergicBannerCallbacks?
    private var observer: NSObjectProtocol?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerView == nil else { return }
        self.callbacks = callbacks

        guard let controller = container.advergicViewController ?? UIView.advergicTopViewController else {
            callbacks.onFailed("Chartboost needs a view controller to load a banner")
            return
        }
        let view = BannerAdView()
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
        observer = ChartboostSupport.observeRevenue(placement: adUnitId, onRevenue: callbacks.onRevenue,
                                             onUnavailable: callbacks.onRevenueUnavailable)

        AdvergicAdapterLog.d("Requesting Chartboost banner for placement \(adUnitId) at \(size)")
        view.load(with: BannerAdLoadRequest(placement: adUnitId, size: Self.bannerSize(size)),
                  viewController: controller) { [weak self] result in
            if let error = result.error {
                let message = ChartboostSupport.message(error)
                AdvergicAdapterLog.w("Chartboost banner failed: \(message)")
                self?.callbacks?.onFailed(message)
            } else {
                self?.callbacks?.onLoaded()
            }
        }
    }

    func destroy() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        bannerView?.reset()
        bannerView?.removeFromSuperview()
        bannerView = nil
        callbacks = nil
    }

    func didClick(bannerView: BannerAdView) {
        callbacks?.onClicked()
    }

    static func bannerSize(_ size: AdvergicAdSize) -> BannerSize {
        switch (size.width, size.height) {
        case (300, 250): return .medium
        case (728, 90): return .leaderboard
        default: return .standard
        }
    }
}

// MARK: Fullscreen

/// Interstitial and rewarded. Chartboost has no app-open format.
final class ChartboostFullscreenAdapter: NSObject, AdvergicFullscreenAdapter, FullscreenAdDelegate {

    private var ad: FullscreenAd?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var observer: NSObjectProtocol?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        clear()
        if format == .appOpen {
            callbacks.onFailed("CHARTBOOST has no app-open format")
            return
        }
        observer = ChartboostSupport.observeRevenue(placement: adUnitId, onRevenue: callbacks.onRevenue,
                                             onUnavailable: callbacks.onRevenueUnavailable)
        AdvergicAdapterLog.d("Requesting Chartboost \(format) for placement \(adUnitId)")
        FullscreenAd.load(with: FullscreenAdLoadRequest(placement: adUnitId)) { [weak self] result in
            guard let self else { return }
            if let ad = result.ad {
                ad.delegate = self
                self.ad = ad
                self.callbacks?.onLoaded()
            } else {
                let message = ChartboostSupport.message(result.error)
                AdvergicAdapterLog.w("Chartboost \(format) failed: \(message)")
                self.callbacks?.onFailed(message)
            }
        }
    }

    func show(from viewController: UIViewController) {
        guard let ad else {
            AdvergicAdapterLog.w("Chartboost show called with no cached ad")
            return
        }
        ad.show(with: viewController) { [weak self] result in
            if let error = result.error {
                self?.callbacks?.onFailed("show failed: \(ChartboostSupport.message(error))")
            } else {
                self?.callbacks?.onShown()
            }
        }
    }

    func destroy() {
        clear()
        callbacks = nil
    }

    private func clear() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        ad?.invalidate()
        ad = nil
    }

    func didClick(ad: FullscreenAd) { callbacks?.onClicked() }

    /// Chartboost's reward carries no amount or type of its own.
    func didReward(ad: FullscreenAd) { callbacks?.onRewardEarned(0, "chartboost") }

    func didClose(ad: FullscreenAd, error: ChartboostMediationError?) {
        // Keep the ILRD observer until close: revenue can land after the impression.
        self.ad = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        callbacks?.onDismissed()
    }

    func didExpire(ad: FullscreenAd) {
        AdvergicAdapterLog.w("Chartboost fullscreen ad expired before it was shown")
    }
}
#endif
