#if canImport(UIKit)
import UIKit

/// Interstitial, rewarded or app-open ad.
///
/// Two-phase, because that is every network's own model: `load` caches an ad and reports
/// `adDidLoad`, then `show(from:)` displays it over a view controller. The gap is the point — an
/// app loads ahead of the moment it wants to interrupt the user.
///
/// ```swift
/// let ad = AdvergicFullscreenAd()
/// ad.listener = self
/// ad.load(format: .interstitial)
/// // later, once adDidLoad has fired
/// ad.show(from: viewController)
/// ```
///
/// A shown ad is spent: `show` after a dismissal does nothing until `load` runs again.
public final class AdvergicFullscreenAd {

    /// Notified about fills, failures, show/dismiss, rewards and revenue. Held weakly.
    public weak var listener: AdvergicFullscreenListener?

    /// True once a load has reported `adDidLoad` and the ad has not yet been shown.
    public private(set) var isReady = false

    private var adapter: AdvergicFullscreenAdapter?
    private var attribution = SlotAttribution()
    private var auction: Task<Void, Never>?
    /// Bumped by every `load` and `destroy`, so callbacks from a superseded request are ignored.
    private var generation = 0

    public init() {}

    /// Requests an ad. Leave `adUnitId` and `network` nil to let the published config decide.
    public func load(format: AdvergicAdFormat, adUnitId: String? = nil, network: AdvergicAdNetwork? = nil) {
        guard let provider = AdsRegistry.provider else {
            AdvergicLog.w(SlotEvents.notInitialized)
            listener?.adDidFailToLoad(message: SlotEvents.notInitialized)
            return
        }

        auction?.cancel()
        isReady = false
        generation += 1
        let current = generation

        AdsRegistry.whenConfigReady(onFailed: { [weak self] reason in
            AdvergicLog.w(reason)
            self?.listener?.adDidFailToLoad(message: reason)
        }) { [weak self] in
            guard let self, self.generation == current else { return }

            if network == nil && adUnitId == nil {
                self.auction = Task { @MainActor [weak self] in
                    let chain = await provider.fullscreenChain(format: format)
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    if let chain, !chain.isEmpty {
                        chain.logResult()
                        self.requestNext(provider, chain: chain, format: format, generation: current, lastError: nil)
                    } else {
                        let target = AdsRegistry.defaultNetwork
                        self.request(provider, target: target, unitId: provider.fullscreenAdUnitId(target, format: format),
                                     format: format, bid: nil, generation: current, onFilled: {}) { [weak self] in
                            self?.listener?.adDidFailToLoad(message: $0)
                        }
                    }
                }
                return
            }

            let target = network ?? AdsRegistry.defaultNetwork
            let unitId = adUnitId.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? provider.fullscreenAdUnitId(target, format: format)
            self.request(provider, target: target, unitId: unitId, format: format, bid: nil,
                         generation: current, onFilled: {}) { [weak self] in
                self?.listener?.adDidFailToLoad(message: $0)
            }
        }
    }

    /// Shows the cached ad. Does nothing, and logs, when `isReady` is false.
    public func show(from viewController: UIViewController) {
        guard let adapter, isReady else {
            AdvergicLog.w("Fullscreen show ignored — no ad is cached")
            return
        }
        adapter.show(from: viewController)
    }

    /// Releases the cached ad. The object can be reused by calling `load` again.
    public func destroy() {
        generation += 1
        auction?.cancel()
        adapter?.destroy()
        adapter = nil
        isReady = false
    }

    /// Unlike a banner, a fullscreen ad is cached rather than displayed on load, so walking the
    /// chain costs only requests — nothing renders until `show`.
    private func requestNext(
        _ provider: AdsProvider, chain: AdChain, format: AdvergicAdFormat, generation: Int, lastError: String?
    ) {
        guard let resolved = chain.next() else {
            let message = chain.exhaustedMessage(lastError: lastError)
            AdvergicLog.w(message)
            listener?.adDidFailToLoad(message: message)
            return
        }
        let rung = resolved.demand
        let tier = chain.position()

        request(
            provider, target: rung.network, unitId: rung.adUnitId, format: format, bid: resolved.bid,
            generation: generation,
            onFilled: { [weak self] in
                self?.attribution = SlotAttribution(placement: chain.placementName, network: rung.network,
                                                    auctionId: chain.auctionId)
                chain.logWinner()
                self?.listener?.adDidFill(network: rung.network, placement: chain.placementName, tier: tier)
            },
            onFailed: { [weak self] reason in
                SlotEvents.rungFailed(chain: chain, rung: rung, tier: tier, reason: reason,
                                      format: format.configName, size: nil)
                self?.requestNext(provider, chain: chain, format: format, generation: generation,
                                  lastError: "\(rung.network): \(reason)")
            }
        )
    }

    private func request(
        _ provider: AdsProvider,
        target: AdvergicAdNetwork,
        unitId: String,
        format: AdvergicAdFormat,
        bid: AdvergicResolvedBid?,
        generation: Int,
        onFilled: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        let initializer = provider.initializer(target)
        initializer.initialize()
        initializer.awaitReady(onReady: { [weak self] in
            guard let self, self.generation == generation else { return }
            self.attach(provider.fullscreenAdapter(target), network: target, unitId: unitId, format: format,
                        bid: bid, generation: generation, onFilled: onFilled, onFailed: onFailed)
        }, onUnavailable: { [weak self] reason in
            guard self?.generation == generation else { return }
            onFailed(reason)
        })
    }

    private func attach(
        _ fullscreenAdapter: AdvergicFullscreenAdapter,
        network: AdvergicAdNetwork,
        unitId: String,
        format: AdvergicAdFormat,
        bid: AdvergicResolvedBid?,
        generation: Int,
        onFilled: @escaping () -> Void,
        onFailed: @escaping (String) -> Void
    ) {
        // A repeat load replaces the previous adapter rather than stacking one per request.
        adapter?.destroy()
        adapter = fullscreenAdapter
        var resolved = false
        let slug = format.configName

        func live(_ body: @escaping (AdvergicFullscreenAd) -> Void) {
            MainThread.post { [weak self] in
                guard let self, self.generation == generation else { return }
                body(self)
            }
        }

        fullscreenAdapter.load(
            adUnitId: unitId,
            format: format,
            bid: bid,
            callbacks: AdvergicFullscreenCallbacks(
                onLoaded: {
                    live { ad in
                        guard !resolved else { return }
                        resolved = true
                        ad.isReady = true
                        onFilled()
                        ad.listener?.adDidLoad()
                    }
                },
                onFailed: { message in
                    live { ad in
                        if resolved {
                            // A show-time failure after a successful load: the ad is spent.
                            ad.isReady = false
                            AdvergicLog.w("Fullscreen show failed: \(message)")
                            ad.listener?.adDidFailToShow(message: message)
                            return
                        }
                        resolved = true
                        ad.isReady = false
                        fullscreenAdapter.destroy()
                        ad.adapter = nil
                        onFailed(message)
                    }
                },
                onShown: { live { $0.listener?.adDidShow() } },
                onDismissed: {
                    live { ad in
                        ad.isReady = false
                        ad.listener?.adDidDismiss()
                    }
                },
                onClicked: {
                    live { ad in
                        SlotEvents.click(format: slug, adUnitId: unitId, network: network, attribution: ad.attribution)
                        ad.listener?.adWasClicked()
                    }
                },
                onRewardEarned: { amount, type in
                    live { $0.listener?.userDidEarnReward(amount: amount, type: type) }
                },
                onRevenue: { revenue in
                    live { ad in
                        SlotEvents.revenue(revenue, format: slug, attribution: ad.attribution)
                        ad.listener?.adDidPayRevenue(revenue)
                    }
                },
                onRevenueUnavailable: { reason in
                    live { $0.listener?.adRevenueUnavailable(reason: reason) }
                }
            )
        )
    }
}
#endif
