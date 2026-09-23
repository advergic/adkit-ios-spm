import Foundation

/// Finds the network modules linked into the app.
///
/// Swift has no classpath to scan, so each module exports its entry point under a fixed
/// Objective-C class name and the core asks the runtime for it. A publisher adds a package and
/// the network is available; a network whose module is absent fails its slots with a message
/// naming the package to add.
enum AdapterDiscovery {

    static func className(for network: AdvergicAdNetwork) -> String {
        switch network {
        case .admobTest: return "AdvergicAdMobAdapter"
        case .yandex: return "AdvergicYandexAdapter"
        case .pangle: return "AdvergicPangleAdapter"
        case .liftoff: return "AdvergicLiftoffAdapter"
        case .meta: return "AdvergicMetaAdapter"
        case .inMobi: return "AdvergicInMobiAdapter"
        case .chartboost: return "AdvergicChartboostAdapter"
        case .appLovin: return "AdvergicAppLovinAdapter"
        case .unityAds: return "AdvergicUnityAdsAdapter"
        case .ironSource: return "AdvergicIronSourceAdapter"
        case .mintegral: return "AdvergicMintegralAdapter"
        case .bidMachine: return "AdvergicBidMachineAdapter"
        case .digitalTurbine: return "AdvergicDigitalTurbineAdapter"
        }
    }

    static func packageName(for network: AdvergicAdNetwork) -> String {
        "AdvergicAdKit" + className(for: network)
            .replacingOccurrences(of: "Advergic", with: "")
            .replacingOccurrences(of: "Adapter", with: "")
    }

    static func notInstalledMessage(_ network: AdvergicAdNetwork) -> String {
        "\(network) adapter is not installed — add the \(packageName(for: network)) product to the app"
    }

    /// Registered by tests (and wrappers that link statically without the ObjC runtime names).
    private static let registered = Locked<[AdvergicAdNetwork: AdvergicNetworkAdapter]>([:])
    private static let cache = Locked<[AdvergicAdNetwork: AdvergicNetworkAdapter]>([:])

    static func register(_ adapter: AdvergicNetworkAdapter) {
        registered.mutate { $0[type(of: adapter).network] = adapter }
        cache.mutate { $0.removeValue(forKey: type(of: adapter).network) }
    }

    static func adapter(for network: AdvergicAdNetwork) -> AdvergicNetworkAdapter? {
        if let explicit = registered.get()[network] { return explicit }
        if let cached = cache.get()[network] { return cached }

        guard let type = NSClassFromString(className(for: network)) as? AdvergicNetworkAdapter.Type,
              type.network == network
        else { return nil }

        let instance = type.init()
        cache.mutate { $0[network] = instance }
        return instance
    }

    static func reset() {
        registered.set([:])
        cache.set([:])
    }
}
