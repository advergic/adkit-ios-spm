#if canImport(UIKit) && canImport(BidMachine)
import BidMachine
import Foundation
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// BidMachine. An exchange rather than a mediator: it runs the auction itself, so every fill
/// carries a real clearing price. Needs a source id; placements are optional.
@objc(AdvergicBidMachineAdapter)
final class BidMachineAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .bidMachine

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        BidMachineInitializer(
            sourceId: setup.credential("source_id", fallback: setup.config.bidMachineSourceId),
            testMode: setup.testMode(fallback: setup.config.bidMachineTestMode),
            verboseLogging: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { BidMachineBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { BidMachineFullscreenAdapter() }

    /// Native ships in a separate artifact on Android and is not wired on either platform.
    func makeNativeAdapter() -> AdvergicNativeAdapter {
        AdvergicPendingNativeAdapter(network: .bidMachine, reason: .unsupported)
    }
}

enum BidMachineSupport {

    static func message(_ error: Error?) -> String {
        guard let nsError = error as NSError? else { return "no ad and no error" }
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    /// Builds the request; a blank placement id still runs the auction.
    static func request(_ format: AdFormat, placementId: String) throws -> BidMachineAuctionRequest {
        let placement = try BidMachineSdk.shared.placement(format) { builder in
            if !placementId.trimmingCharacters(in: .whitespaces).isEmpty {
                builder.withPlacementId(placementId)
            }
        }
        return BidMachineSdk.shared.auctionRequest(placement: placement)
    }

    /// The price cleared an auction rather than being estimated, hence precision `auction`.
    static func report(_ auction: BidMachineAuctionResponseProtocol?, adUnitId: String,
                       onRevenue: (AdvergicAdRevenue) -> Void, onUnavailable: (String) -> Void) {
        guard let auction, auction.price > 0 else {
            onUnavailable("BidMachine disclosed no price for this fill")
            return
        }
        onRevenue(AdvergicAdRevenue(
            amount: auction.price,
            currencyCode: "USD",
            amountUsd: auction.price,
            precision: "auction",
            network: auction.demandSource.isEmpty ? "bidmachine" : auction.demandSource,
            adUnitId: adUnitId
        ))
    }
}

final class BidMachineInitializer: AdvergicBaseInitializer {

    private let sourceId: String
    private let testMode: Bool
    private let verboseLogging: Bool

    init(sourceId: String, testMode: Bool, verboseLogging: Bool) {
        self.sourceId = sourceId
        self.testMode = testMode
        self.verboseLogging = verboseLogging
        super.init(networkName: AdvergicAdNetwork.bidMachine.name)
    }

    override func start() {
        if isPlaceholder(sourceId) {
            markUnavailable(missingCredential("source id"))
            return
        }
        BidMachineSdk.shared.populate { builder in
            builder.withTestMode(testMode)
            builder.withLoggingMode(verboseLogging)
        }
        AdvergicAdapterLog.d("Starting BidMachine \(BidMachineSdk.sdkVersion) with source id \(sourceId), testMode=\(testMode)")
        // BidMachine's init is synchronous and reports nothing back; requests before it has
        // finished are queued by the SDK itself.
        BidMachineSdk.shared.initializeSdk(sourceId)
        markReady()
    }
}

// MARK: Banner

final class BidMachineBannerAdapter: NSObject, AdvergicBannerAdapter, BidMachineAdDelegate {

    private var banner: BidMachineBanner?
    private weak var container: UIView?
    private var callbacks: AdvergicBannerCallbacks?
    private var adUnitId = ""
    private var size: AdvergicAdSize = .banner

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard banner == nil else { return }
        self.container = container
        self.callbacks = callbacks
        self.adUnitId = adUnitId
        self.size = size

        let request: BidMachineAuctionRequest
        do {
            request = try BidMachineSupport.request(Self.format(size), placementId: adUnitId)
        } catch {
            callbacks.onFailed("BidMachine placement rejected: \(BidMachineSupport.message(error))")
            return
        }
        AdvergicAdapterLog.d("Requesting BidMachine banner at \(size)")
        BidMachineSdk.shared.banner(request: request) { [weak self] ad, error in
            guard let self else { return }
            guard let ad else {
                self.fail(error)
                return
            }
            ad.delegate = self
            ad.controller = container.advergicViewController ?? UIView.advergicTopViewController
            self.banner = ad
            ad.loadAd()
        }
    }

    func destroy() {
        banner?.delegate = nil
        banner?.removeFromSuperview()
        banner = nil
        callbacks = nil
    }

    private func fail(_ error: Error?) {
        let message = BidMachineSupport.message(error)
        AdvergicAdapterLog.w("BidMachine banner failed: \(message)")
        callbacks?.onFailed(message)
    }

    func didLoadAd(_ ad: BidMachineAdProtocol) {
        guard let banner, let container else { return }
        banner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            banner.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
            banner.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
        ])
        callbacks?.onLoaded()
    }

    func didFailLoadAd(_ ad: BidMachineAdProtocol, _ error: Error) { fail(error) }

    func didTrackImpression(_ ad: BidMachineAdProtocol) {
        guard let callbacks else { return }
        BidMachineSupport.report(ad.auctionInfo, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                                 onUnavailable: callbacks.onRevenueUnavailable)
    }

    func didUserInteraction(_ ad: BidMachineAdProtocol) {
        callbacks?.onClicked()
    }

    static func format(_ size: AdvergicAdSize) -> AdFormat {
        switch size {
        case .mediumRectangle: return .banner300x250
        case .leaderboard: return .banner728x90
        default: return .banner320x50
        }
    }
}

// MARK: Fullscreen

final class BidMachineFullscreenAdapter: NSObject, AdvergicFullscreenAdapter, BidMachineAdDelegate {

    private var interstitial: BidMachineInterstitial?
    private var rewarded: BidMachineRewarded?
    private var callbacks: AdvergicFullscreenCallbacks?
    private var adUnitId = ""

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        self.adUnitId = adUnitId
        interstitial = nil
        rewarded = nil
        if format == .appOpen {
            callbacks.onFailed("BIDMACHINE has no app-open format")
            return
        }
        let request: BidMachineAuctionRequest
        do {
            request = try BidMachineSupport.request(format == .rewarded ? .rewarded : .interstitial, placementId: adUnitId)
        } catch {
            callbacks.onFailed("BidMachine placement rejected: \(BidMachineSupport.message(error))")
            return
        }
        AdvergicAdapterLog.d("Requesting BidMachine \(format)")
        if format == .rewarded {
            BidMachineSdk.shared.rewarded(request: request) { [weak self] ad, error in
                guard let self else { return }
                guard let ad else { return self.fail(error) }
                ad.delegate = self
                self.rewarded = ad
                ad.loadAd()
            }
        } else {
            BidMachineSdk.shared.interstitial(request: request) { [weak self] ad, error in
                guard let self else { return }
                guard let ad else { return self.fail(error) }
                ad.delegate = self
                self.interstitial = ad
                ad.loadAd()
            }
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial, interstitial.canShow {
            interstitial.controller = viewController
            interstitial.presentAd()
        } else if let rewarded, rewarded.canShow {
            rewarded.controller = viewController
            rewarded.presentAd()
        } else {
            AdvergicAdapterLog.w("BidMachine show called with no ready ad")
        }
    }

    func destroy() {
        interstitial = nil
        rewarded = nil
        callbacks = nil
    }

    private func fail(_ error: Error?) {
        let message = BidMachineSupport.message(error)
        AdvergicAdapterLog.w("BidMachine fullscreen failed: \(message)")
        callbacks?.onFailed(message)
    }

    func didLoadAd(_ ad: BidMachineAdProtocol) { callbacks?.onLoaded() }
    func didFailLoadAd(_ ad: BidMachineAdProtocol, _ error: Error) { fail(error) }
    func didPresentAd(_ ad: BidMachineAdProtocol) { callbacks?.onShown() }
    func didFailPresentAd(_ ad: BidMachineAdProtocol, _ error: Error) {
        callbacks?.onFailed("show failed: \(BidMachineSupport.message(error))")
    }
    func didUserInteraction(_ ad: BidMachineAdProtocol) { callbacks?.onClicked() }

    func didTrackImpression(_ ad: BidMachineAdProtocol) {
        guard let callbacks else { return }
        BidMachineSupport.report(ad.auctionInfo, adUnitId: adUnitId, onRevenue: callbacks.onRevenue,
                                 onUnavailable: callbacks.onRevenueUnavailable)
    }

    /// BidMachine's reward carries no amount or type of its own.
    func didReceiveReward(_ ad: BidMachineAdProtocol) {
        callbacks?.onRewardEarned(0, "bidmachine")
    }

    func didDismissAd(_ ad: BidMachineAdProtocol) {
        interstitial = nil
        rewarded = nil
        callbacks?.onDismissed()
    }
}
#endif
