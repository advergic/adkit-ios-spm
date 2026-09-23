#if canImport(UIKit)
import UIKit

/// Stands in for a format a network doesn't offer, or one not wired up yet — and says which.
///
/// The distinction matters: `notIntegrated` is work the SDK could do, while `unsupported` is a
/// format the network does not have, so no dashboard change will ever produce a fill.
@_spi(AdvergicAdapters)
public enum AdvergicUnavailableReason {
    case notIntegrated
    case unsupported
}

@_spi(AdvergicAdapters)
public final class AdvergicPendingNativeAdapter: AdvergicNativeAdapter {
    private let network: String
    private let reason: AdvergicUnavailableReason

    public init(network: AdvergicAdNetwork, reason: AdvergicUnavailableReason) {
        self.network = network.name
        self.reason = reason
    }

    public func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        let message: String
        switch reason {
        case .notIntegrated: message = "\(network) native is not wired up in the SDK yet"
        case .unsupported: message = "\(network) has no native format"
        }
        AdvergicLog.w(message)
        callbacks.onFailed(message)
    }

    public func destroy() {}
}

/// Fails fullscreen loads for formats a network lacks, naming the network and format rather
/// than staying silent — a slot that never calls back looks exactly like one still loading.
@_spi(AdvergicAdapters)
public final class AdvergicPendingFullscreenAdapter: AdvergicFullscreenAdapter {
    private let network: String
    private let reason: AdvergicUnavailableReason

    public init(network: AdvergicAdNetwork, reason: AdvergicUnavailableReason) {
        self.network = network.name
        self.reason = reason
    }

    public func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
                     callbacks: AdvergicFullscreenCallbacks) {
        let message: String
        switch reason {
        case .notIntegrated: message = "\(network) \(format) is not wired up in the SDK yet"
        case .unsupported: message = "\(network) has no \(format.configName.replacingOccurrences(of: "_", with: "-")) format"
        }
        AdvergicLog.w(message)
        callbacks.onFailed(message)
    }

    public func show(from viewController: UIViewController) {}
    public func destroy() {}
}

/// Used when the network's module isn't linked at all.
final class MissingAdapter: AdvergicBannerAdapter, AdvergicNativeAdapter {
    private let message: String

    init(network: AdvergicAdNetwork) {
        message = AdapterDiscovery.notInstalledMessage(network)
    }

    func attach(container: UIView, adUnitId: String, size: AdvergicAdSize, bid: AdvergicResolvedBid?,
                callbacks: AdvergicBannerCallbacks) {
        callbacks.onFailed(message)
    }

    func attach(container: UIView, adUnitId: String, callbacks: AdvergicBannerCallbacks) {
        callbacks.onFailed(message)
    }

    func destroy() {}
}

final class MissingFullscreenAdapter: AdvergicFullscreenAdapter {
    private let message: String

    init(network: AdvergicAdNetwork) {
        message = AdapterDiscovery.notInstalledMessage(network)
    }

    func load(adUnitId: String, format: AdvergicAdFormat, bid: AdvergicResolvedBid?,
              callbacks: AdvergicFullscreenCallbacks) {
        callbacks.onFailed(message)
    }

    func show(from viewController: UIViewController) {}
    func destroy() {}
}
#endif
