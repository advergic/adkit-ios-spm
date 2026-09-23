import Foundation

/// The ordered demand a slot works through, and where it currently is.
///
/// The order is the auction result. Each rung is tried only once the one above it failed:
/// an ad that loads and is never shown still counts as a fill against the app.
///
/// Single-use, owned by one slot, driven from the main thread. Log lines match the Android SDK
/// word for word so support material applies to both.
final class AdChain {

    let placementName: String
    private let rungs: [ResolvedDemand]
    /// What the slot asked for, e.g. `banner 320x50` — labels the decision log.
    private let request: String
    private var index = -1

    /// Ties this slot's events together: ranking, fill, each failed rung, and the revenue that
    /// eventually arrives.
    let auctionId = UUID().uuidString.lowercased()

    private(set) var current: ResolvedDemand?

    init(placementName: String, rungs: [ResolvedDemand], request: String = "") {
        self.placementName = placementName
        self.rungs = rungs
        self.request = request
    }

    var size: Int { rungs.count }
    var isEmpty: Bool { rungs.isEmpty }
    var networks: [AdvergicAdNetwork] { rungs.map(\.demand.network) }

    /// Advances to the next rung, or nil once every one has been tried.
    func next() -> ResolvedDemand? {
        index += 1
        current = index < rungs.count ? rungs[index] : nil
        if let current { logAttempt(current) }
        return current
    }

    /// 1-based, for logs that read "tier 2 of 5".
    func position() -> Int { index + 1 }

    /// The auction result, before anything is requested.
    func logResult() {
        guard let top = rungs.first else {
            AdvergicLog.d("[auction] \(request) → \(placementName): no demand configured")
            return
        }
        let bids = rungs.filter(\.isRealBid).count
        let learned = rungs.filter(\.isLearned).count
        AdvergicLog.d(
            "[auction] \(request) → \(placementName), \(rungs.count) candidate(s), " +
                "\(bids) real bid(s), \(learned) observed price(s), ranked by price:"
        )
        for (position, rung) in rungs.enumerated() {
            AdvergicLog.d(
                "[auction]   \(position + 1). \(rung.demand.network) \(rung.describe()) " +
                    "\(rung.demand.adUnitId) (\(rung.demand.label))"
            )
        }

        var attrs: Attributes = [
            "auction.id": .string(auctionId),
            "placement.name": .string(placementName),
            "auction.request": .string(request),
            "auction.candidate_count": .of(rungs.count),
            "auction.bidder_count": .of(bids),
            "auction.observed_count": .of(learned),
            // Ranked first — not necessarily who serves. ad.fill reports that.
            "winner.network": .string(top.demand.network.name),
            "winner.ad_unit_id": .string(top.demand.adUnitId),
            "winner.price": .double(top.price),
            "winner.currency": .string(top.currency),
            "winner.price_type": .string(top.basis),
        ]
        if rungs.count > 1 {
            let second = rungs[1]
            attrs["runner_up.network"] = .string(second.demand.network.name)
            attrs["runner_up.price"] = .double(second.price)
            attrs["runner_up.price_type"] = .string(second.basis)
            attrs["auction.price_gap"] = .double(top.price - second.price)
        }
        attrs["participants"] = .array(rungs.enumerated().map { position, rung in
            var entry: [String: AttributeValue] = [
                "network": .string(rung.demand.network.name),
                "ad_unit_id": .string(rung.demand.adUnitId),
                "label": .string(rung.demand.label),
                "rank": .of(position + 1),
                "price": .double(rung.price),
                "currency": .string(rung.currency),
                "price_type": .string(rung.basis),
            ]
            if let floor = rung.demand.floor { entry["floor"] = .double(floor) }
            return .map(entry)
        })
        Analytics.track("auction.completed", attrs)
    }

    func logWinner() {
        guard let rung = current else { return }
        let how = rung.isRealBid ? "highest bid"
            : rung.isLearned ? "highest observed price"
            : "highest floor — no price observed yet"
        AdvergicLog.i(
            "[auction] \(request) → \(rung.demand.network) WON at tier \(position())/\(size) " +
                "\(rung.describe()) — \(how), \(placementName), unit \(rung.demand.adUnitId)"
        )

        // A win at tier 5 says the four above it are failing — invisible from revenue alone.
        Telemetry.info(
            "Load OK",
            "\(rung.demand.network) filled \(placementName) at tier \(position())/\(size) (\(how))",
            adUnitId: rung.demand.adUnitId,
            adUnitType: placementName,
            attrs: [
                "ad.network": .string(rung.demand.network.name),
                "auction.tier": .string(String(position())),
                "auction.candidates": .string(String(size)),
                "auction.basis": .string(rung.basis),
                "auction.request": .string(request),
            ]
        )

        Analytics.track("ad.fill", [
            "auction.id": .string(auctionId),
            "placement.name": .string(placementName),
            "ad.network": .string(rung.demand.network.name),
            "ad.unit_id": .string(rung.demand.adUnitId),
            "chain.tier": .of(position()),
            "chain.size": .of(size),
            "price": .double(rung.price),
            "currency": .string(rung.currency),
            "price_type": .string(rung.basis),
        ])
    }

    /// Why nothing filled, listing what was tried — the rung names point straight at dashboard rows.
    func exhaustedMessage(lastError: String?) -> String {
        guard !rungs.isEmpty else {
            Telemetry.warn(
                "No Demand", "No demand configured for \(placementName)",
                adUnitType: placementName, attrs: ["auction.request": .string(request)]
            )
            return "no demand configured for \(placementName)"
        }
        let tried = rungs.map { rung in
            "\(rung.demand.network):\(rung.demand.label.isEmpty ? rung.demand.adUnitId : rung.demand.label)"
        }.joined(separator: ", ")
        let tail = lastError.map { " Last error: \($0)" } ?? ""

        Telemetry.warn(
            "Chain Exhausted", "No fill for \(placementName) after \(rungs.count) tier(s)",
            error: lastError,
            adUnitType: placementName,
            attrs: [
                "auction.candidates": .string(String(rungs.count)),
                "auction.tried": .string(tried),
                "auction.request": .string(request),
            ]
        )
        return "no fill for \(placementName) after \(rungs.count) tier(s): \(tried).\(tail)"
    }

    private func logAttempt(_ rung: ResolvedDemand) {
        let reason = index == 0
            ? (rung.isRealBid ? "won the auction" : "highest price — nobody bid higher")
            : "every candidate above it failed to fill"
        AdvergicLog.d(
            "[auction] \(placementName) tier \(position())/\(size): \(rung.demand.network) " +
                "\(rung.describe()) — \(reason)"
        )
    }
}
