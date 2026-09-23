import Foundation

/// Stands in for a network that must not start — gated off by the config, or whose adapter
/// module isn't linked into the app.
///
/// Never touches the network's SDK, so no device identifier reaches a network the publisher has
/// not registered with. Waiting slots are failed with the reason rather than left hanging.
final class DisabledAdsInitializer: AdvergicAdsInitializer {

    private let networkName: String
    private let reason: String
    private let logged = Locked(false)

    init(networkName: String, reason: String) {
        self.networkName = networkName
        self.reason = reason
    }

    var isReady: Bool { false }

    /// Every slot calls this, so the reason is logged once rather than per request.
    func initialize() {
        let first = logged.mutate { value -> Bool in
            defer { value = true }
            return !value
        }
        if first { AdvergicLog.d("Not starting \(networkName): \(reason)") }
    }

    func awaitReady(onReady: @escaping () -> Void, onUnavailable: @escaping (String) -> Void) {
        MainThread.post { [reason] in onUnavailable(reason) }
    }
}
