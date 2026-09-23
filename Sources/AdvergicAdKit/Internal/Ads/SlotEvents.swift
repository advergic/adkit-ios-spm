import Foundation

/// Which placement and network a slot's current fill belongs to, so a price reported later can
/// be attributed. Set per attempt: revenue often arrives well after the fill, and crediting the
/// wrong rung would teach the auction the wrong thing.
struct SlotAttribution {
    var placement: String?
    var network: AdvergicAdNetwork?
    var auctionId: String?
}

/// The reporting every slot does on the same events — shared so banner, native and fullscreen
/// cannot drift apart in what they send.
enum SlotEvents {

    static let notInitialized = "Advergic.initialize() has not been called — no ad requested"

    /// Whatever it paid becomes the estimate for the next auction, however late it arrived.
    static func revenue(_ revenue: AdvergicAdRevenue, format: String, attribution: SlotAttribution) {
        if let placement = attribution.placement, let network = attribution.network {
            AdPriceHistory.record(network: network, placement: placement, price: revenue.amount)
        }
        AdsRegistry.mmp.report(revenue, format: format)
        Telemetry.revenue(revenue, format: format)

        var attrs: Attributes = [
            "ad.network": .string(revenue.network),
            "ad.unit_id": .string(revenue.adUnitId),
            "ad.format": .string(format),
            "revenue.amount": .double(revenue.amount),
            "revenue.currency": .string(revenue.currencyCode),
            // An auction price and a network's own estimate both arrive here; only this
            // separates them.
            "revenue.precision": .string(revenue.precision),
        ]
        if let id = attribution.auctionId { attrs["auction.id"] = .string(id) }
        if let placement = attribution.placement { attrs["placement.name"] = .string(placement) }
        if let usd = revenue.amountUsd { attrs["revenue.amount_usd"] = .double(usd) }
        Analytics.track("ad.revenue", attrs)
    }

    static func click(format: String?, adUnitId: String?, network: AdvergicAdNetwork, attribution: SlotAttribution) {
        var attrs: Attributes = ["ad.network": .string((attribution.network ?? network).name)]
        if let format { attrs["ad.format"] = .string(format) }
        if let adUnitId { attrs["ad.unit_id"] = .string(adUnitId) }
        if let id = attribution.auctionId { attrs["auction.id"] = .string(id) }
        if let placement = attribution.placement { attrs["placement.name"] = .string(placement) }
        Analytics.track("ad.click", attrs)
    }

    /// Per network, per tier. A network that never fills is invisible in revenue reporting, so
    /// this is the only place "lost the auction" and "broken integration" differ.
    static func rungFailed(
        chain: AdChain, rung: RemoteDemand, tier: Int, reason: String,
        format: String?, size: AdvergicAdSize?
    ) {
        AdvergicLog.d("\(rung.network) did not fill: \(reason)")

        var analytics: Attributes = [
            "auction.id": .string(chain.auctionId),
            "placement.name": .string(chain.placementName),
            "ad.network": .string(rung.network.name),
            "ad.unit_id": .string(rung.adUnitId),
            "chain.tier": .of(tier),
            "chain.size": .of(chain.size),
            "error.message": .string(reason),
        ]
        if let format { analytics["ad.format"] = .string(format) }
        Analytics.track("ad.load_failed", analytics)

        var attrs: Attributes = [
            "ad.network": .string(rung.network.name),
            "auction.tier": .string(String(tier)),
        ]
        if let size { attrs["ad.size"] = .string(size.description) }
        Telemetry.warn(
            "Load Fail",
            "\(rung.network) did not fill \(chain.placementName)",
            error: reason,
            adUnitId: rung.adUnitId,
            adUnitType: format ?? chain.placementName,
            attrs: attrs
        )
    }
}
