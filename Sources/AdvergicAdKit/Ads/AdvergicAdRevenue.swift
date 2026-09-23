import Foundation

/// Impression-level revenue for a single ad, normalised across networks.
public struct AdvergicAdRevenue: CustomStringConvertible, Sendable {

    /// What the impression paid, in `currencyCode` units.
    public let amount: Double

    /// ISO-4217 code reported by the network.
    public let currencyCode: String

    /// The same impression in USD when the network discloses it. `nil` when only a
    /// foreign-currency figure exists — the SDK will not invent an exchange rate.
    public let amountUsd: Double?

    /// How much to trust `amount` — the network's own label (AdMob's `ESTIMATED`, `PRECISE`, …,
    /// or `auction` for a cleared bid).
    public let precision: String

    /// Demand source that paid, when the stack discloses it.
    public let network: String

    /// Slot the impression was served into.
    public let adUnitId: String

    @_spi(AdvergicAdapters)
    public init(
        amount: Double,
        currencyCode: String,
        amountUsd: Double?,
        precision: String,
        network: String,
        adUnitId: String
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.amountUsd = amountUsd
        self.precision = precision
        self.network = network
        self.adUnitId = adUnitId
    }

    public var description: String {
        var text = "AdvergicAdRevenue(amount=\(amount) \(currencyCode)"
        if let usd = amountUsd { text += " [~$\(usd)]" }
        text += ", precision=\(precision), network=\(network), adUnitId=\(adUnitId))"
        return text
    }
}
