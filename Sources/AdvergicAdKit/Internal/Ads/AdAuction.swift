import Foundation

/// A demand source with the price it will pay, once known.
///
/// `isRealBid` is the distinction that matters: a real bid is what the impression *will* pay,
/// cleared before anything was fetched. Conflating it with an estimate in the logs is how a
/// network ends up "winning" on a number nobody measured.
struct ResolvedDemand {
    let demand: RemoteDemand
    let price: Double
    let isRealBid: Bool
    /// True when `price` is what this network was observed paying, not a configured guess.
    var isLearned = false
    /// Opaque winning payload, for networks that load with it.
    var payload: String?
    var currency = "USD"

    func describe() -> String {
        if isRealBid { return String(format: "[BID $%.4f %@]", price, currency) }
        if isLearned { return String(format: "[observed $%.4f]", price) }
        return String(format: "[floor $%.4f]", price)
    }

    var basis: String { isRealBid ? "bid" : isLearned ? "observed" : "floor" }

    var bid: AdvergicResolvedBid? {
        guard isRealBid, let payload else { return nil }
        return AdvergicResolvedBid(payload: payload, price: price, currency: currency)
    }
}

/// Runs the auction for one slot.
///
/// Every entry that can price itself **before its ad is fetched** is asked, in parallel, and the
/// results are ranked by what came back. Everything else keeps its observed price or floor —
/// loading every network to discover its price would burn a fill on six networks to use one.
enum AdAuction {

    /// A bid arriving after the user has scrolled past is worth nothing. 3s because the measured
    /// cost is token generation plus a round trip through the publisher's backend to Meta.
    static let timeout: TimeInterval = 3

    /// Source of pre-load bidder tokens; the Meta module in production, a fake in tests.
    typealias TokenSource = (AdvergicAdNetwork) async -> String?

    static let defaultTokenSource: TokenSource = { network in
        await AdapterDiscovery.adapter(for: network)?.bidderToken()
    }

    /// Prices for `entries`, best first. Never throws: a bidder that fails, times out or returns
    /// nothing falls back to its estimate, so a broken auction degrades to the waterfall rather
    /// than to no ad.
    static func resolve(
        entries: [RemoteDemand],
        size: AdvergicAdSize?,
        placement: String,
        bidProvider: AdvergicMetaBidProvider? = MetaBidRegistry.provider,
        tokenSource: @escaping TokenSource = defaultTokenSource
    ) async -> [ResolvedDemand] {
        guard !entries.isEmpty else { return [] }

        let resolved = await withTaskGroup(of: (Int, ResolvedDemand).self) { group -> [ResolvedDemand] in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    if canBid(entry, provider: bidProvider), let provider = bidProvider,
                       let bid = await bid(entry, size: size, provider: provider, tokenSource: tokenSource) {
                        return (index, bid)
                    }
                    return (index, estimate(entry, placement: placement))
                }
            }
            var results = [(Int, ResolvedDemand)]()
            for await result in group { results.append(result) }
            // Stable for equal prices: published order breaks ties, as the Android sort does.
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return stableSortedDescending(resolved)
    }

    /// Meta only, for now. AdMob and Yandex never can: both report on impression.
    static func canBid(_ entry: RemoteDemand, provider: AdvergicMetaBidProvider?) -> Bool {
        entry.network == .meta && provider != nil
    }

    private static func bid(
        _ entry: RemoteDemand,
        size: AdvergicAdSize?,
        provider: AdvergicMetaBidProvider,
        tokenSource: @escaping TokenSource
    ) async -> ResolvedDemand? {
        // Meta bids on banner shapes; a fullscreen slot has no size to quote.
        let shape = size ?? .banner

        return await withTimeout(timeout) {
            guard let token = await tokenSource(entry.network), !token.isEmpty else {
                AdvergicLog.w("[auction] \(entry.network): no bidder token, using estimate")
                return nil
            }
            do {
                let bid = try await provider.fetchMetaBid(
                    placementId: entry.adUnitId, bidderToken: token, size: shape
                )
                // A bidding floor is a constraint: below it the bid is refused, not ranked.
                if let floor = entry.floor, bid.price < floor {
                    AdvergicLog.d(String(format: "[auction] %@ bid $%.4f is under its floor $%.4f — rejected",
                                         entry.network.name, bid.price, floor))
                    return nil
                }
                return ResolvedDemand(demand: entry, price: bid.price, isRealBid: true,
                                      payload: bid.payload, currency: bid.currency)
            } catch {
                AdvergicLog.d("[auction] \(entry.network) did not bid: \(error.localizedDescription)")
                return nil
            }
        } ?? nil
    }

    /// An observed price beats the configured floor: it is what the network actually paid here.
    static func estimate(_ entry: RemoteDemand, placement: String) -> ResolvedDemand {
        let learned = AdPriceHistory.observed(network: entry.network, placement: placement)
        return ResolvedDemand(
            demand: entry,
            price: learned ?? entry.floor ?? 0,
            isRealBid: false,
            isLearned: learned != nil
        )
    }

    private static func stableSortedDescending(_ items: [ResolvedDemand]) -> [ResolvedDemand] {
        items.enumerated()
            .sorted { lhs, rhs in
                lhs.element.price != rhs.element.price
                    ? lhs.element.price > rhs.element.price
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Runs `operation`, returning nil if it has not finished within `seconds`.
///
/// Returns at the deadline even if `operation` ignores cancellation — a bid provider blocked on
/// a slow backend must not hold the slot. The operation is cancelled and its late result dropped.
func withTimeout<T>(_ seconds: TimeInterval, _ operation: @escaping () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumed = Locked(false)
        let finish: (T?) -> Void = { value in
            let first = resumed.mutate { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        let task = Task { finish(await operation()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            finish(nil)
            task.cancel()
        }
    }
}
