#if canImport(UIKit) && canImport(PAGAdSDK)
import Foundation
import PAGAdSDK
import UIKit
@_spi(AdvergicAdapters) import AdvergicAdKit

/// Pangle (ByteDance). A demand source that discloses no price. App ids and slot ids are per
/// platform — an Android slot id is rejected on iOS.
@objc(AdvergicPangleAdapter)
final class PangleAdapter: NSObject, AdvergicNetworkAdapter {

    static let network: AdvergicAdNetwork = .pangle

    required override init() {
        super.init()
    }

    func makeInitializer(setup: AdvergicNetworkSetup) -> AdvergicAdsInitializer {
        PangleInitializer(
            appId: setup.credential("app_id", fallback: setup.config.pangleAppId),
            debugLog: setup.enableLogging
        )
    }

    func makeBannerAdapter() -> AdvergicBannerAdapter { PangleBannerAdapter() }
    func makeFullscreenAdapter() -> AdvergicFullscreenAdapter { PangleFullscreenAdapter() }
    func makeNativeAdapter() -> AdvergicNativeAdapter { PangleNativeAdapter() }
}

enum Pangle {
    static let noPrice = "Pangle discloses no price to the SDK"

    /// The numeric code separates a no-fill from a rejected slot or an app id that doesn't own
    /// it; the message alone flattens them.
    static func message(_ error: Error?) -> String {
        guard let nsError = error as NSError? else { return "no ad and no error" }
        return "\(nsError.localizedDescription) (code=\(nsError.code))"
    }

    static func isPlaceholder(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespaces).isEmpty || id.hasPrefix("REPLACE_WITH")
    }
}

final class PangleInitializer: AdvergicBaseInitializer {

    private let appId: String
    private let debugLog: Bool

    init(appId: String, debugLog: Bool) {
        self.appId = appId
        self.debugLog = debugLog
        super.init(networkName: AdvergicAdNetwork.pangle.name)
    }

    override func start() {
        if isPlaceholder(appId) {
            markUnavailable(missingCredential("app id"))
            return
        }
        AdvergicAdapterLog.d("Starting Pangle \(PAGSdk.sdkVersion) with app id \(appId)")
        let config = PAGConfig.share()
        config.appID = appId
        config.debugLog = debugLog
        // Pangle refuses to serve until a personalised-ads consent value is declared: every
        // request answers 10008 "user compliance status verification is incomplete". Declared
        // as consent, matching Android — a shipping app must set it from its own CMP.
        config.paConsent = .consent
        PAGSdk.start(with: config) { [weak self] success, error in
            if success {
                self?.markReady()
            } else {
                self?.markUnavailable("Pangle init failed: \(Pangle.message(error))")
            }
        }
    }
}

// MARK: Banner

final class PangleBannerAdapter: NSObject, AdvergicBannerAdapter, PAGBannerAdDelegate {

    private var bannerAd: PAGBannerAd?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        guard bannerAd == nil else { return }
        self.callbacks = callbacks

        if Pangle.isPlaceholder(adUnitId) {
            callbacks.onFailed("Pangle banner slot id is not set")
            return
        }
        let pangleSize = Self.adSize(size)
        AdvergicAdapterLog.d("Requesting Pangle banner for slot \(adUnitId) (requested \(size))")

        PAGBannerAd.load(withSlotID: adUnitId, request: PAGBannerRequest(bannerSize: pangleSize)) { [weak self, weak container] ad, error in
            guard let self else { return }
            guard let ad, let container else {
                let message = Pangle.message(error)
                AdvergicAdapterLog.w("Pangle banner failed: \(message)")
                self.callbacks?.onFailed(message)
                return
            }
            self.bannerAd = ad
            ad.delegate = self
            ad.rootViewController = container.advergicViewController ?? UIView.advergicTopViewController
            let view = ad.bannerView
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: CGFloat(size.width)),
                view.heightAnchor.constraint(equalToConstant: CGFloat(size.height)),
            ])
            self.callbacks?.onLoaded()
        }
    }

    func destroy() {
        bannerAd?.delegate = nil
        bannerAd?.bannerView.removeFromSuperview()
        bannerAd = nil
        callbacks = nil
    }

    func adDidShow(_ ad: PAGAdProtocol) { callbacks?.onRevenueUnavailable(Pangle.noPrice) }
    func adDidClick(_ ad: PAGAdProtocol) { callbacks?.onClicked() }

    static func adSize(_ size: AdvergicAdSize) -> PAGBannerAdSize {
        switch (size.width, size.height) {
        case (300, 250): return kPAGBannerSize300x250
        case (728, 90): return kPAGBannerSize728x90
        default: return kPAGBannerSize320x50
        }
    }
}

// MARK: Fullscreen

final class PangleFullscreenAdapter: NSObject, AdvergicFullscreenAdapter,
    PAGLInterstitialAdDelegate, PAGRewardedAdDelegate, PAGLAppOpenAdDelegate {

    private var interstitial: PAGLInterstitialAd?
    private var rewarded: PAGRewardedAd?
    private var appOpen: PAGLAppOpenAd?
    private var callbacks: AdvergicFullscreenCallbacks?

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        self.callbacks = callbacks
        clear()
        if Pangle.isPlaceholder(adUnitId) {
            callbacks.onFailed("Pangle \(format) slot id is not set")
            return
        }
        AdvergicAdapterLog.d("Requesting Pangle \(format) for slot \(adUnitId)")

        switch format {
        case .interstitial:
            PAGLInterstitialAd.load(withSlotID: adUnitId, request: PAGInterstitialRequest()) { [weak self] ad, error in
                guard let self else { return }
                if let ad { ad.delegate = self; self.interstitial = ad; self.callbacks?.onLoaded() }
                else { self.failed(format, error) }
            }
        case .rewarded:
            PAGRewardedAd.load(withSlotID: adUnitId, request: PAGRewardedRequest()) { [weak self] ad, error in
                guard let self else { return }
                if let ad { ad.delegate = self; self.rewarded = ad; self.callbacks?.onLoaded() }
                else { self.failed(format, error) }
            }
        case .appOpen:
            PAGLAppOpenAd.load(withSlotID: adUnitId, request: PAGAppOpenRequest()) { [weak self] ad, error in
                guard let self else { return }
                if let ad { ad.delegate = self; self.appOpen = ad; self.callbacks?.onLoaded() }
                else { self.failed(format, error) }
            }
        }
    }

    func show(from viewController: UIViewController) {
        if let interstitial { interstitial.present(fromRootViewController: viewController) }
        else if let rewarded { rewarded.present(fromRootViewController: viewController) }
        else if let appOpen { appOpen.present(fromRootViewController: viewController) }
        else { AdvergicAdapterLog.w("Pangle show called with no cached ad") }
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

    private func failed(_ format: AdvergicAdFormat, _ error: Error?) {
        let message = Pangle.message(error)
        AdvergicAdapterLog.w("Pangle \(format) failed: \(message)")
        callbacks?.onFailed(message)
    }

    func adDidShow(_ ad: PAGAdProtocol) {
        callbacks?.onShown()
        callbacks?.onRevenueUnavailable(Pangle.noPrice)
    }

    func adDidClick(_ ad: PAGAdProtocol) { callbacks?.onClicked() }

    func adDidDismiss(_ ad: PAGAdProtocol) {
        clear()
        callbacks?.onDismissed()
    }

    func rewardedAd(_ rewardedAd: PAGRewardedAd, userDidEarnReward rewardModel: PAGRewardModel) {
        callbacks?.onRewardEarned(rewardModel.rewardAmount, rewardModel.rewardName)
    }

    func rewardedAd(_ rewardedAd: PAGRewardedAd, userEarnRewardFailWithError error: Error) {
        AdvergicAdapterLog.w("Pangle reward failed: \(Pangle.message(error))")
    }
}

// MARK: Native

/// Pangle hands back its own media view and logo, placed inside the template; the icon arrives
/// as a URL.
final class PangleNativeAdapter: NSObject, AdvergicNativeAdapter, PAGLNativeAdDelegate {

    private var nativeAd: PAGLNativeAd?
    private var relatedView: PAGLNativeAdRelatedView?
    private var template: AdvergicNativeTemplateView?
    private weak var container: UIView?
    private var callbacks: AdvergicBannerCallbacks?

    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        guard nativeAd == nil else { return }
        self.container = container
        self.callbacks = callbacks
        if Pangle.isPlaceholder(adUnitId) {
            callbacks.onFailed("Pangle native slot id is not set")
            return
        }
        AdvergicAdapterLog.d("Requesting Pangle native for slot \(adUnitId)")
        PAGLNativeAd.load(withSlotID: adUnitId, request: PAGNativeRequest()) { [weak self] ad, error in
            guard let self else { return }
            guard let ad else {
                let message = Pangle.message(error)
                AdvergicAdapterLog.w("Pangle native failed: \(message)")
                self.callbacks?.onFailed(message)
                return
            }
            self.render(ad)
        }
    }

    func destroy() {
        nativeAd?.unregisterView()
        nativeAd?.delegate = nil
        nativeAd = nil
        relatedView = nil
        template?.removeFromSuperview()
        template = nil
        callbacks = nil
    }

    private func render(_ ad: PAGLNativeAd) {
        guard let container else { return }
        nativeAd = ad
        ad.delegate = self
        ad.rootViewController = container.advergicViewController ?? UIView.advergicTopViewController

        let related = PAGLNativeAdRelatedView()
        related.refresh(with: ad)
        relatedView = related

        let template = AdvergicNativeTemplateView()
        template.bind(headline: ad.data.adTitle, advertiser: nil, body: ad.data.adDescription,
                      callToAction: ad.data.buttonText, icon: nil)
        template.setMedia(related.mediaView)
        template.disclosureStack.addArrangedSubview(related.logoADImageView)
        AdvergicNativeTemplateView.pin(template, in: container)
        self.template = template

        if let url = URL(string: ad.data.icon.imageURL) {
            URLSession.shared.dataTask(with: url) { [weak template] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    template?.iconView.image = image
                    template?.iconView.isHidden = false
                }
            }.resume()
        }

        ad.registerContainer(template, withClickableViews: [template.callToActionButton, template.headlineLabel])
        callbacks?.onLoaded()
    }

    func adDidShow(_ ad: PAGAdProtocol) { callbacks?.onRevenueUnavailable(Pangle.noPrice) }
    func adDidClick(_ ad: PAGAdProtocol) { callbacks?.onClicked() }
}
#endif
