#if canImport(UIKit)
import UIKit

/// Banner ad slot.
///
/// Add it to your hierarchy and call `load(size:)`, or use the `AdvergicBanner` SwiftUI view.
/// The request is held until the SDK has a config and the chosen network has initialized, so it
/// is safe to load immediately — including before `Advergic.initialize` has resolved.
///
/// Call `destroy()` when the screen goes away; the SwiftUI wrapper does that for you.
public final class AdvergicBannerView: UIView {

    /// Notified about fills, failures, clicks and impression revenue. Held weakly.
    public weak var listener: AdvergicAdListener?

    private var adapter: AdvergicBannerAdapter?
    private var attribution = SlotAttribution()
    private var requestedSize: AdvergicAdSize = .banner
    private var auction: Task<Void, Never>?
    private var destroyed = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: requestedSize.width, height: requestedSize.height)
    }

    /// Requests a banner.
    ///
    /// Leave `adUnitId` and `network` nil: the published config decides. Naming either pins the
    /// slot to that network — the diagnostic path.
    public func load(adUnitId: String? = nil, network: AdvergicAdNetwork? = nil, size: AdvergicAdSize = .banner) {
        requestedSize = size
        invalidateIntrinsicContentSize()

        guard let provider = AdsRegistry.provider else {
            AdvergicLog.w(SlotEvents.notInitialized)
            listener?.adDidFailToLoad(message: SlotEvents.notInitialized)
            return
        }

        AdsRegistry.whenConfigReady(onFailed: { [weak self] reason in
            // Reported rather than left hanging: an empty slot with no callback looks exactly
            // like one still loading.
            AdvergicLog.w(reason)
            self?.listener?.adDidFailToLoad(message: reason)
        }) { [weak self] in
            guard let self, !self.destroyed else { return }

            if network == nil && adUnitId == nil {
                self.auction = Task { @MainActor [weak self] in
                    let chain = await provider.bannerChain(size: size)
                    guard let self, !self.destroyed, !Task.isCancelled else { return }
                    if let chain, !chain.isEmpty {
                        chain.logResult()
                        self.requestNext(provider, chain: chain, size: size, lastError: nil)
                    } else {
                        let target = AdsRegistry.defaultNetwork
                        self.request(provider, target: target, unitId: provider.bannerAdUnitId(target, size: size),
                                     size: size, bid: nil, onFilled: {}) { [weak self] in
                            self?.listener?.adDidFailToLoad(message: $0)
                        }
                    }
                }
                return
            }

            let target = network ?? AdsRegistry.defaultNetwork
            let unitId = adUnitId.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? provider.bannerAdUnitId(target, size: size)
            self.request(provider, target: target, unitId: unitId, size: size, bid: nil, onFilled: {}) { [weak self] in
                self?.listener?.adDidFailToLoad(message: $0)
            }
        }
    }

    /// Releases the underlying ad view. The slot cannot be reused afterwards.
    public func destroy() {
        destroyed = true
        auction?.cancel()
        adapter?.destroy()
        adapter = nil
        subviews.forEach { $0.removeFromSuperview() }
    }

    /// Tries one rung, and on failure moves to the next. A tier is attempted only once the one
    /// above it failed: several SDKs count a banner impression on render.
    private func requestNext(_ provider: AdsProvider, chain: AdChain, size: AdvergicAdSize, lastError: String?) {
        guard let resolved = chain.next() else {
            let message = chain.exhaustedMessage(lastError: lastError)
            AdvergicLog.w(message)
            listener?.adDidFailToLoad(message: message)
            return
        }
        let rung = resolved.demand
        let tier = chain.position()

        request(
            provider, target: rung.network, unitId: rung.adUnitId, size: size, bid: resolved.bid,
            onFilled: { [weak self] in
                self?.attribution = SlotAttribution(placement: chain.placementName, network: rung.network,
                                                    auctionId: chain.auctionId)
                chain.logWinner()
                self?.listener?.adDidFill(network: rung.network, placement: chain.placementName, tier: tier)
            },
            onFailed: { [weak self] reason in
                SlotEvents.rungFailed(chain: chain, rung: rung, tier: tier, reason: reason, format: nil, size: size)
                self?.requestNext(provider, chain: chain, size: size, lastError: "\(rung.network): \(reason)")
            }
        )
    }

    private func request(
        _ provider: AdsProvider,
        target: AdvergicAdNetwork,
        unitId: String,
        size: AdvergicAdSize,
        bid: AdvergicResolvedBid?,
        onFilled: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        let initializer = provider.initializer(target)
        initializer.initialize()
        initializer.awaitReady(onReady: { [weak self] in
            guard let self, !self.destroyed else { return }
            self.attach(provider.bannerAdapter(target), network: target, unitId: unitId, size: size, bid: bid,
                        onFilled: onFilled, onFailed: onFailed)
        }, onUnavailable: onFailed)
    }

    private func attach(
        _ bannerAdapter: AdvergicBannerAdapter,
        network: AdvergicAdNetwork,
        unitId: String,
        size: AdvergicAdSize,
        bid: AdvergicResolvedBid?,
        onFilled: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        guard adapter == nil else { return }
        adapter = bannerAdapter

        // A rung resolves once. Some SDKs report a failure twice for one request, which would
        // otherwise skip a tier per duplicate.
        var resolved = false

        bannerAdapter.attach(
            container: self,
            adUnitId: unitId,
            size: size,
            bid: bid,
            callbacks: AdvergicBannerCallbacks(
                onLoaded: { [weak self] in
                    MainThread.post {
                        guard !resolved else { return }
                        resolved = true
                        onFilled()
                        self?.listener?.adDidLoad()
                    }
                },
                onFailed: { [weak self] message in
                    MainThread.post {
                        guard !resolved else { return }
                        resolved = true
                        // Release the failed adapter before the next tier attaches: it may have
                        // added a view, and the slot holds one adapter at a time.
                        bannerAdapter.destroy()
                        self?.subviews.forEach { $0.removeFromSuperview() }
                        self?.adapter = nil
                        onFailed(message)
                    }
                },
                onClicked: { [weak self] in
                    MainThread.post {
                        guard let self else { return }
                        SlotEvents.click(format: nil, adUnitId: unitId, network: network, attribution: self.attribution)
                        self.listener?.adWasClicked()
                    }
                },
                onRevenue: { [weak self] revenue in
                    MainThread.post {
                        guard let self else { return }
                        SlotEvents.revenue(revenue, format: "banner", attribution: self.attribution)
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
