import Foundation

/// Lifecycle of a single in-layout slot (banner or native). All callbacks arrive on the main
/// thread, and every method has an empty default — implement only what you need.
public protocol AdvergicAdListener: AnyObject {

    func adDidLoad()

    /// Which demand won, once the chain resolves. Fires just before `adDidLoad` when the config
    /// chose the network; not fired when the caller pinned the slot.
    ///
    /// - Parameters:
    ///   - network: Demand source that filled.
    ///   - placement: Published placement the chain came from.
    ///   - tier: 1-based position in the chain; 1 means the top rung filled.
    func adDidFill(network: AdvergicAdNetwork, placement: String, tier: Int)

    /// - Parameter message: Why the fill failed, as reported by the ad stack.
    func adDidFailToLoad(message: String)

    func adWasClicked()

    /// Impression-level revenue, fired once per paid impression.
    func adDidPayRevenue(_ revenue: AdvergicAdRevenue)

    /// The ad served but the network reported no price, and won't. "Paid nothing" and "did not
    /// say" are different facts; `adDidPayRevenue` will not follow.
    func adRevenueUnavailable(reason: String)
}

public extension AdvergicAdListener {
    func adDidLoad() {}
    func adDidFill(network: AdvergicAdNetwork, placement: String, tier: Int) {}
    func adDidFailToLoad(message: String) {}
    func adWasClicked() {}
    func adDidPayRevenue(_ revenue: AdvergicAdRevenue) {}
    func adRevenueUnavailable(reason: String) {}
}

/// Lifecycle of a fullscreen slot. Adds the events only a fullscreen ad has.
public protocol AdvergicFullscreenListener: AdvergicAdListener {

    /// The ad is now covering the screen.
    func adDidShow()

    /// The user dismissed the ad. It is spent — showing again needs a fresh load.
    func adDidDismiss()

    /// The ad loaded but could not be presented. It is spent; `adDidDismiss` will not follow, so
    /// resume whatever you paused for it here.
    func adDidFailToShow(message: String)

    /// Rewarded only. Fired before `adDidDismiss` when the user earns the reward; a user who
    /// closes early never triggers it, which is what makes it usable as a grant signal.
    func userDidEarnReward(amount: Int, type: String)
}

public extension AdvergicFullscreenListener {
    func adDidShow() {}
    func adDidDismiss() {}
    func adDidFailToShow(message: String) {}
    func userDidEarnReward(amount: Int, type: String) {}
}
