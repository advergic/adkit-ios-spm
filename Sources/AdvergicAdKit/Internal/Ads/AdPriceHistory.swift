import Foundation

/// What each network has actually paid, learned at runtime.
///
/// Only Meta can price itself before load; everyone else discloses at load (InMobi) or after the
/// impression (AdMob, Yandex, mediators). Ranking those on a number typed into the dashboard means
/// a network paying $1.17 loses to one configured at $0.40 forever. So every observed price is
/// recorded against `NETWORK:placement` and ranks the next request; the floor becomes a bootstrap.
///
/// An exponential moving average, so one unusual fill cannot pin a network to the top.
enum AdPriceHistory {

    /// Weight of the newest observation.
    static let alpha = 0.3

    /// Below this an observation means "no price disclosed", not zero — AdMob's test units report
    /// exactly 0.0, and learning from that would teach the SDK AdMob is worthless.
    static let minMeaningful = 0.000001

    private static let suiteName = "com.advergic.adkit.price-history"

    private struct State {
        var defaults: UserDefaults?
        var observed: [String: Double] = [:]
    }

    private static let state = Locked(State())

    /// Loads the persisted history. Survives relaunch, or every cold start ranks on floors again.
    static func attach(defaults: UserDefaults? = nil) {
        state.mutate { current in
            guard current.defaults == nil else { return }
            let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
            current.defaults = store
            for (key, value) in store.dictionaryRepresentation() where key.contains(":") {
                if let number = value as? Double { current.observed[key] = number }
            }
            if !current.observed.isEmpty {
                AdvergicLog.d("[auction] loaded \(current.observed.count) learned price(s)")
            }
        }
    }

    /// Records what an impression paid, whenever it arrived — a late price is still the best
    /// estimate for the next request.
    static func record(network: AdvergicAdNetwork, placement: String, price: Double) {
        guard price >= minMeaningful, price.isFinite else { return }
        let key = self.key(network, placement)

        let (next, store) = state.mutate { current -> (Double, UserDefaults?) in
            let next = current.observed[key].map { $0 * (1 - alpha) + price * alpha } ?? price
            current.observed[key] = next
            return (next, current.defaults)
        }

        AdvergicLog.d(String(format: "[auction] learned %@ %@: paid $%.6f, running estimate $%.6f",
                             network.name, placement, price, next))
        store?.set(next, forKey: key)
    }

    /// What `network` is expected to pay here, or nil if it has never disclosed a price.
    static func observed(network: AdvergicAdNetwork, placement: String) -> Double? {
        state.get().observed[key(network, placement)]
    }

    /// Test/shutdown hook.
    static func reset(clearStore: Bool = true) {
        state.mutate { current in
            if clearStore, let store = current.defaults {
                for key in current.observed.keys { store.removeObject(forKey: key) }
            }
            current = State()
        }
    }

    private static func key(_ network: AdvergicAdNetwork, _ placement: String) -> String {
        "\(network.name):\(placement)"
    }
}
