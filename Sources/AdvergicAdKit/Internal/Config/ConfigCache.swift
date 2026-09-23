import Foundation

/// The last config the middleware returned, kept on disk.
///
/// The config decides which networks may start and which ad units they request, so a slow or
/// unreachable middleware would otherwise mean no ads on every cold start for every user on a bad
/// connection. Only ever a *fallback*: the fetch always runs, and a fresh response replaces this.
protocol ConfigCache: AnyObject {
    func load() -> AdvergicRemoteConfig?
    func save(_ config: AdvergicRemoteConfig)
    func clear()
}

/// No persistence — tests, and any host that opts out.
final class NoConfigCache: ConfigCache {
    func load() -> AdvergicRemoteConfig? { nil }
    func save(_ config: AdvergicRemoteConfig) {}
    func clear() {}
}

final class UserDefaultsConfigCache: ConfigCache {

    /// 24h. Long enough to cover a bad day of connectivity, short enough to stay honest: a stale
    /// config can name ad units that no longer exist, or keep starting a network the publisher
    /// has since disconnected — the one thing the gate exists to prevent.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private static let suiteName = "com.advergic.adkit.config-cache"
    private static let keyBody = "body"
    private static let keySavedAt = "saved_at"

    private let defaults: UserDefaults
    private let clock: Clock

    init(defaults: UserDefaults? = nil, clock: Clock = .system) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
        self.clock = clock
    }

    func load() -> AdvergicRemoteConfig? {
        guard let raw = defaults.string(forKey: Self.keyBody) else { return nil }
        let savedAt = defaults.double(forKey: Self.keySavedAt)
        let age = clock.now().timeIntervalSince1970 - savedAt

        if age > Self.maxAge {
            AdvergicLog.d("Cached config is \(Int(age / 3600))h old — too stale to use")
            return nil
        }

        guard let config = AdvergicRemoteConfig.parse(raw) else {
            AdvergicLog.w("Cached config could not be parsed; ignoring it")
            return nil
        }
        return config
    }

    func save(_ config: AdvergicRemoteConfig) {
        defaults.set(config.raw, forKey: Self.keyBody)
        defaults.set(clock.now().timeIntervalSince1970, forKey: Self.keySavedAt)
    }

    /// Called when the server rejects this app (401/403): serving from a config it would no
    /// longer issue is exactly what the publisher check exists to stop.
    func clear() {
        defaults.removeObject(forKey: Self.keyBody)
        defaults.removeObject(forKey: Self.keySavedAt)
    }
}
