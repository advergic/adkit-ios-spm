import Foundation

/// Slot size requested from the ad stack, in points.
///
/// The four constants are the IAB sizes every network supports natively. `custom` exists for
/// anything else, but non-standard sizes match very little demand — a full-screen shape like
/// 320x480 is served as an *interstitial* by every network, not as a banner.
public struct AdvergicAdSize: Hashable, CustomStringConvertible, Sendable {

    public let width: Int
    public let height: Int

    private init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    /// 320x50 — the standard mobile banner.
    public static let banner = AdvergicAdSize(320, 50)

    /// 320x100 — double-height banner.
    public static let largeBanner = AdvergicAdSize(320, 100)

    /// 300x250 — the MREC, the best-supported non-banner size.
    public static let mediumRectangle = AdvergicAdSize(300, 250)

    /// 728x90 — tablet leaderboard.
    public static let leaderboard = AdvergicAdSize(728, 90)

    /// Any other size. Expect thin demand.
    public static func custom(width: Int, height: Int) -> AdvergicAdSize {
        AdvergicAdSize(width, height)
    }

    public var description: String { "\(width)x\(height)" }
}
