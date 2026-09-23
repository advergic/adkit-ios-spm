#if canImport(UIKit)
import UIKit

/// Native ad slot.
///
/// Renders in the layout like a banner, but the network supplies assets and the adapter binds
/// them into a view it builds — so there is **no requested size**; the height follows the content.
public final class AdvergicNativeAdView: UIView {

    /// Notified about fills, failures, clicks and impression revenue. Held weakly.
    public weak var listener: AdvergicAdListener?

    private var adapter: AdvergicNativeAdapter?
    private var attribution = SlotAttribution()
    private var auction: Task<Void, Never>?
    private var destroyed = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The height the bound assets need at the current width. Zero until an ad has loaded, so an
    /// empty slot takes no space.
    public override var intrinsicContentSize: CGSize {
        guard let content = subviews.first else { return CGSize(width: UIView.noIntrinsicMetric, height: 0) }
        let width = bounds.width > 0 ? bounds.width : 320
        let fitted = content.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height))
    }

    private var lastWidth: CGFloat = 0

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Text wraps differently at a new width, so the height has to be re-measured.
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    /// Requests a native ad. Leave both arguments nil to let the published config decide.
    public func load(adUnitId: String? = nil, network: AdvergicAdNetwork? = nil) {
        guard let provider = AdsRegistry.provider else {
            AdvergicLog.w(SlotEvents.notInitialized)
            listener?.adDidFailToLoad(message: SlotEvents.notInitialized)
            return
        }

        AdsRegistry.whenConfigReady(onFailed: { [weak self] reason in
            AdvergicLog.w(reason)
            self?.listener?.adDidFailToLoad(message: reason)
        }) { [weak self] in
            guard let self, !self.destroyed else { return }

            if network == nil && adUnitId == nil {
                self.auction = Task { @MainActor [weak self] in
                    let chain = await provider.nativeChain()
                    guard let self, !self.destroyed, !Task.isCancelled else { return }
                    if let chain, !chain.isEmpty {
                        chain.logResult()
                        self.requestNext(provider, chain: chain, lastError: nil)
                    } else {
                        let target = AdsRegistry.defaultNetwork
                        self.request(provider, target: target, unitId: provider.nativeAdUnitId(target),
                                     onFilled: {}) { [weak self] in self?.listener?.adDidFailToLoad(message: $0) }
                    }
                }
                return
            }

            let target = network ?? AdsRegistry.defaultNetwork
            let unitId = adUnitId.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? provider.nativeAdUnitId(target)
            self.request(provider, target: target, unitId: unitId, onFilled: {}) { [weak self] in
                self?.listener?.adDidFailToLoad(message: $0)
            }
        }
    }

    /// Releases the underlying ad. The slot cannot be reused afterwards.
    public func destroy() {
        destroyed = true
        auction?.cancel()
        adapter?.destroy()
        adapter = nil
        subviews.forEach { $0.removeFromSuperview() }
    }

    private func requestNext(_ provider: AdsProvider, chain: AdChain, lastError: String?) {
        guard let resolved = chain.next() else {
            let message = chain.exhaustedMessage(lastError: lastError)
            AdvergicLog.w(message)
            listener?.adDidFailToLoad(message: message)
            return
        }
        let rung = resolved.demand
        let tier = chain.position()

        request(
            provider, target: rung.network, unitId: rung.adUnitId,
            onFilled: { [weak self] in
                self?.attribution = SlotAttribution(placement: chain.placementName, network: rung.network,
                                                    auctionId: chain.auctionId)
                chain.logWinner()
                self?.listener?.adDidFill(network: rung.network, placement: chain.placementName, tier: tier)
            },
            onFailed: { [weak self] reason in
                SlotEvents.rungFailed(chain: chain, rung: rung, tier: tier, reason: reason, format: "native", size: nil)
                self?.requestNext(provider, chain: chain, lastError: "\(rung.network): \(reason)")
            }
        )
    }

    private func request(
        _ provider: AdsProvider,
        target: AdvergicAdNetwork,
        unitId: String,
        onFilled: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        let initializer = provider.initializer(target)
        initializer.initialize()
        initializer.awaitReady(onReady: { [weak self] in
            guard let self, !self.destroyed else { return }
            self.attach(provider.nativeAdapter(target), network: target, unitId: unitId,
                        onFilled: onFilled, onFailed: onFailed)
        }, onUnavailable: onFailed)
    }

    private func attach(
        _ nativeAdapter: AdvergicNativeAdapter,
        network: AdvergicAdNetwork,
        unitId: String,
        onFilled: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        guard adapter == nil else { return }
        adapter = nativeAdapter
        var resolved = false

        nativeAdapter.attach(
            container: self,
            adUnitId: unitId,
            callbacks: AdvergicBannerCallbacks(
                onLoaded: { [weak self] in
                    MainThread.post {
                        guard !resolved else { return }
                        resolved = true
                        self?.invalidateIntrinsicContentSize()
                        onFilled()
                        self?.listener?.adDidLoad()
                    }
                },
                onFailed: { [weak self] message in
                    MainThread.post {
                        guard !resolved else { return }
                        resolved = true
                        nativeAdapter.destroy()
                        self?.subviews.forEach { $0.removeFromSuperview() }
                        self?.adapter = nil
                        onFailed(message)
                    }
                },
                onClicked: { [weak self] in
                    MainThread.post {
                        guard let self else { return }
                        SlotEvents.click(format: "native", adUnitId: nil, network: network, attribution: self.attribution)
                        self.listener?.adWasClicked()
                    }
                },
                onRevenue: { [weak self] revenue in
                    MainThread.post {
                        guard let self else { return }
                        SlotEvents.revenue(revenue, format: "native", attribution: self.attribution)
                        self.listener?.adDidPayRevenue(revenue)
                    }
                },
                onRevenueUnavailable: { [weak self] reason in
                    MainThread.post { self?.listener?.adRevenueUnavailable(reason: reason) }
                }
            )
        )
    }
}
#endif
