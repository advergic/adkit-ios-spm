import Foundation

/// A winning bid from Meta Audience Network, as returned by an `AdvergicMetaBidProvider`.
///
/// Meta's SDK never discloses what a plain fill paid. Bidding is the exception: the auction
/// happens before the ad is fetched, so the clearing price is known up front.
public struct AdvergicMetaBid: Sendable, Equatable {

    /// The opaque `adm` payload from the bid response, handed straight to Meta's
    /// `loadAd(withBidPayload:)`.
    public let payload: String

    /// Clearing price, in `currency` units.
    public let price: Double

    /// ISO-4217 code the bid was quoted in.
    public let currency: String

    /// Meta's identifier for the bid, for reconciling against Meta's reporting.
    public let bidId: String?

    public init(payload: String, price: Double, currency: String = "USD", bidId: String? = nil) {
        self.payload = payload
        self.price = price
        self.currency = currency
        self.bidId = bidId
    }
}

/// Supplies Meta bids to the SDK.
///
/// The bid request itself cannot run in the app: Meta authenticates it with an HMAC of the
/// **app secret**, which must never ship in a client binary. The SDK's job stops at producing the
/// bidder token; your backend turns it into a bid.
public protocol AdvergicMetaBidProvider: AnyObject {

    /// - Parameters:
    ///   - placementId: Meta placement, `<appId>_<placementId>`.
    ///   - bidderToken: Fresh token from `Advergic.metaBidderToken()`.
    ///   - size: Slot being filled. Meta only bids on banner heights 50 and 250.
    /// - Returns: The winning bid. Throw when nobody bid.
    func fetchMetaBid(
        placementId: String,
        bidderToken: String,
        size: AdvergicAdSize
    ) async throws -> AdvergicMetaBid
}
