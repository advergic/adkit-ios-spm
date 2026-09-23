import Foundation

/// Hands the live ad machinery to the ad slots, which the host app constructs and so can't be
/// injected through an initializer. Also holds the gate that keeps every ad stack from starting
/// until the middleware has recognised this app.
///
/// Gate state is touched on the main thread only; the rest is lock-protected.
enum AdsRegistry {

    private struct Waiter {
        let onReady: () -> Void
        let onFailed: (String) -> Void
    }

    private struct State {
        var provider: AdsProvider?
        var defaultNetwork: AdvergicAdNetwork = .admobTest
        var enabledNetworks: [AdvergicAdNetwork] = []
        var mmp: MmpReporter = NoMmpReporter()
    }

    private static let state = Locked(State())

    static var provider: AdsProvider? {
        get { state.get().provider }
        set { state.mutate { $0.provider = newValue } }
    }

    static var defaultNetwork: AdvergicAdNetwork {
        get { state.get().defaultNetwork }
        set { state.mutate { $0.defaultNetwork = newValue } }
    }

    /// Networks the config allows. Empty until the config lands.
    static var enabledNetworks: [AdvergicAdNetwork] {
        get { state.get().enabledNetworks }
        set { state.mutate { $0.enabledNetworks = newValue } }
    }

    /// Where impression revenue is forwarded for attribution. A no-op by default, so a slot never
    /// has to know whether an MMP is connected.
    static var mmp: MmpReporter {
        get { state.get().mmp }
        set { state.mutate { $0.mmp = newValue } }
    }

    // Main-thread only.
    private static var waiters: [Waiter] = []
    private(set) static var isConfigReady = false
    /// Why no config could be applied. Slots arriving afterwards fail immediately rather than
    /// queueing behind a gate that will never open.
    private(set) static var configFailure: String?

    static func markConfigReady() {
        MainThread.post {
            guard !isConfigReady else { return }
            isConfigReady = true
            configFailure = nil
            drain().forEach { $0.onReady() }
        }
    }

    /// Every waiting slot is told why. Without this they wait forever: an empty space, no
    /// callback, and nothing tying it to the config call that failed.
    static func markConfigFailed(_ reason: String) {
        MainThread.post {
            // A config that already applied wins: a later refresh failing does not invalidate it.
            guard !isConfigReady else { return }
            configFailure = reason
            drain().forEach { $0.onFailed(reason) }
        }
    }

    static func whenConfigReady(onFailed: @escaping (String) -> Void = { _ in }, _ block: @escaping () -> Void) {
        MainThread.post {
            if isConfigReady {
                block()
            } else if let failure = configFailure {
                onFailed(failure)
            } else {
                waiters.append(Waiter(onReady: block, onFailed: onFailed))
            }
        }
    }

    private static func drain() -> [Waiter] {
        let queued = waiters
        waiters.removeAll()
        return queued
    }

    /// Test/shutdown hook: forgets everything so a later initialize starts clean.
    static func reset() {
        state.set(State())
        MainThread.post {
            isConfigReady = false
            configFailure = nil
            waiters.removeAll()
        }
    }
}

/// Holds the Meta bid provider, if the host app registered one.
enum MetaBidRegistry {
    private static let ref = Locked<AdvergicMetaBidProvider?>(nil)

    static var provider: AdvergicMetaBidProvider? {
        get { ref.get() }
        set { ref.set(newValue) }
    }

    static func reset() { ref.set(nil) }
}

/// Lets the Meta module run its own auction on a pinned slot, where no chain resolved a bid.
@_spi(AdvergicAdapters)
public enum AdvergicMetaBidding {
    public static var provider: AdvergicMetaBidProvider? { MetaBidRegistry.provider }
}
