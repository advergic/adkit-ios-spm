#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

/// Banner slot for SwiftUI — the component publishers import:
///
/// ```swift
/// AdvergicBanner(size: .banner)
/// ```
///
/// Requests a fill when it appears and releases the ad when it leaves the hierarchy. Safe to
/// place before `Advergic.initialize` has resolved. Sizes itself to `size`.
@available(iOS 13.0, *)
public struct AdvergicBanner: View {

    let adUnitId: String?
    let network: AdvergicAdNetwork?
    let size: AdvergicAdSize
    let callbacks: AdvergicSlotCallbacks

    /// - Parameters:
    ///   - adUnitId: Pins the slot to one unit. Leave nil — the config decides.
    ///   - network: Pins the slot to one network. Leave nil — the config decides.
    ///   - size: Slot size; the standard 320x50 banner by default.
    public init(
        adUnitId: String? = nil,
        network: AdvergicAdNetwork? = nil,
        size: AdvergicAdSize = .banner,
        onAdLoaded: @escaping () -> Void = {},
        onAdFilled: @escaping (AdvergicAdNetwork, String, Int) -> Void = { _, _, _ in },
        onAdLoadFailed: @escaping (String) -> Void = { _ in },
        onAdClicked: @escaping () -> Void = {},
        onAdRevenuePaid: @escaping (AdvergicAdRevenue) -> Void = { _ in },
        onAdRevenueUnavailable: @escaping (String) -> Void = { _ in }
    ) {
        self.adUnitId = adUnitId
        self.network = network
        self.size = size
        callbacks = AdvergicSlotCallbacks(
            loaded: onAdLoaded, filled: onAdFilled, failed: onAdLoadFailed,
            clicked: onAdClicked, revenue: onAdRevenuePaid, noRevenue: onAdRevenueUnavailable
        )
    }

    public var body: some View {
        BannerRepresentable(adUnitId: adUnitId, network: network, size: size, callbacks: callbacks)
            .frame(width: CGFloat(size.width), height: CGFloat(size.height))
    }
}

/// Native slot for SwiftUI. No size: the returned assets set the shape.
@available(iOS 13.0, *)
public struct AdvergicNative: View {

    let adUnitId: String?
    let network: AdvergicAdNetwork?
    let callbacks: AdvergicSlotCallbacks

    public init(
        adUnitId: String? = nil,
        network: AdvergicAdNetwork? = nil,
        onAdLoaded: @escaping () -> Void = {},
        onAdFilled: @escaping (AdvergicAdNetwork, String, Int) -> Void = { _, _, _ in },
        onAdLoadFailed: @escaping (String) -> Void = { _ in },
        onAdClicked: @escaping () -> Void = {},
        onAdRevenuePaid: @escaping (AdvergicAdRevenue) -> Void = { _ in },
        onAdRevenueUnavailable: @escaping (String) -> Void = { _ in }
    ) {
        self.adUnitId = adUnitId
        self.network = network
        callbacks = AdvergicSlotCallbacks(
            loaded: onAdLoaded, filled: onAdFilled, failed: onAdLoadFailed,
            clicked: onAdClicked, revenue: onAdRevenuePaid, noRevenue: onAdRevenueUnavailable
        )
    }

    public var body: some View {
        NativeRepresentable(adUnitId: adUnitId, network: network, callbacks: callbacks)
            // Take the height the assets need rather than whatever the container proposes.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Closure-to-listener bridge. Updated on every SwiftUI render so the latest closures fire —
/// the equivalent of Compose's `rememberUpdatedState`.
final class AdvergicSlotCallbacks: AdvergicAdListener {
    var loaded: () -> Void
    var filled: (AdvergicAdNetwork, String, Int) -> Void
    var failed: (String) -> Void
    var clicked: () -> Void
    var revenue: (AdvergicAdRevenue) -> Void
    var noRevenue: (String) -> Void

    init(
        loaded: @escaping () -> Void,
        filled: @escaping (AdvergicAdNetwork, String, Int) -> Void,
        failed: @escaping (String) -> Void,
        clicked: @escaping () -> Void,
        revenue: @escaping (AdvergicAdRevenue) -> Void,
        noRevenue: @escaping (String) -> Void
    ) {
        self.loaded = loaded
        self.filled = filled
        self.failed = failed
        self.clicked = clicked
        self.revenue = revenue
        self.noRevenue = noRevenue
    }

    func update(from other: AdvergicSlotCallbacks) {
        loaded = other.loaded
        filled = other.filled
        failed = other.failed
        clicked = other.clicked
        revenue = other.revenue
        noRevenue = other.noRevenue
    }

    func adDidLoad() { loaded() }
    func adDidFill(network: AdvergicAdNetwork, placement: String, tier: Int) { filled(network, placement, tier) }
    func adDidFailToLoad(message: String) { failed(message) }
    func adWasClicked() { clicked() }
    func adDidPayRevenue(_ revenue: AdvergicAdRevenue) { self.revenue(revenue) }
    func adRevenueUnavailable(reason: String) { noRevenue(reason) }
}

@available(iOS 13.0, *)
private struct BannerRepresentable: UIViewRepresentable {
    let adUnitId: String?
    let network: AdvergicAdNetwork?
    let size: AdvergicAdSize
    let callbacks: AdvergicSlotCallbacks

    // The coordinator owns the listener, since the view holds it weakly.
    func makeCoordinator() -> AdvergicSlotCallbacks { callbacks }

    func makeUIView(context: Context) -> AdvergicBannerView {
        let view = AdvergicBannerView()
        view.listener = context.coordinator
        view.load(adUnitId: adUnitId, network: network, size: size)
        return view
    }

    func updateUIView(_ view: AdvergicBannerView, context: Context) {
        context.coordinator.update(from: callbacks)
    }

    static func dismantleUIView(_ view: AdvergicBannerView, coordinator: AdvergicSlotCallbacks) {
        view.destroy()
    }
}

@available(iOS 13.0, *)
private struct NativeRepresentable: UIViewRepresentable {
    let adUnitId: String?
    let network: AdvergicAdNetwork?
    let callbacks: AdvergicSlotCallbacks

    func makeCoordinator() -> AdvergicSlotCallbacks { callbacks }

    func makeUIView(context: Context) -> AdvergicNativeAdView {
        let view = AdvergicNativeAdView()
        view.listener = context.coordinator
        view.load(adUnitId: adUnitId, network: network)
        return view
    }

    func updateUIView(_ view: AdvergicNativeAdView, context: Context) {
        context.coordinator.update(from: callbacks)
    }

    static func dismantleUIView(_ view: AdvergicNativeAdView, coordinator: AdvergicSlotCallbacks) {
        view.destroy()
    }
}
#endif
