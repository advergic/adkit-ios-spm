import Foundation

/// One demand source inside a placement's band.
struct RemoteDemand: Equatable {
    let network: AdvergicAdNetwork
    let adUnitId: String
    let label: String
    /// Bid constraint in the bidding band; expected eCPM in the waterfall.
    let floor: Double?
    let enabled: Bool
}

/// A placement as the dashboard published it.
struct RemotePlacement: CustomStringConvertible {
    let id: String
    let name: String
    let format: String
    /// Nil for formats with no fixed shape, and for adaptive banners.
    let width: Int?
    let height: Int?
    let adaptive: Bool
    /// Networks that return a price before display.
    let bidding: [RemoteDemand]
    /// Networks priced on an observed price or their floor.
    let waterfall: [RemoteDemand]

    /// Every enabled network referenced here, whichever band it sits in.
    func networks() -> Set<AdvergicAdNetwork> {
        Set(candidates().map(\.network))
    }

    func matches(width: Int, height: Int) -> Bool {
        self.width == width && self.height == height
    }

    /// Every enabled candidate, in no particular order: ranking is the auction's job, not the
    /// config's. Which array an entry sat in only says where its price is expected to come from.
    func candidates() -> [RemoteDemand] {
        (bidding + waterfall).filter(\.enabled)
    }

    var description: String {
        let size = width.map { " \($0)x\(height ?? 0)" } ?? ""
        return "\(name)(\(format)\(size), \(bidding.count) bidding, \(waterfall.count) waterfall)"
    }
}

/// A network the publisher connected, with the credentials they entered.
struct RemotePlatform: CustomStringConvertible {
    let network: AdvergicAdNetwork
    let credentials: [String: String]

    func credential(_ key: String) -> String? {
        guard let value = credentials[key], !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }

    /// Test flags ride in the same free-form credentials object — the dashboard's network catalog
    /// defines those fields per network.
    var testMode: Bool? {
        switch credentials["test_mode"] {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    var testDevices: [String] {
        (credentials["test_devices"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var description: String { "\(network)(credentials=\(credentials.keys.sorted()))" }
}

/// The mediation config the middleware published for this app.
///
/// Answers two questions. **May this network start** — `connectedNetworks` holds one entry per
/// network the publisher connected, so presence is the gate. **What does it request** —
/// `mediation.placements` carries the ad unit ids.
///
/// **A document with no `connectedNetworks` key means "no opinion", not "nothing enabled".**
/// Some deployments still answer with the older mobile config. Once the key is present it is
/// authoritative — including when empty.
struct RemoteAdsConfig: CustomStringConvertible {

    private let platforms: [AdvergicAdNetwork: RemotePlatform]
    let placements: [RemotePlacement]
    let version: Int
    /// Whether the document carried `connectedNetworks` at all.
    private let declared: Bool

    /// Networks that may start: connected *and* referenced by an enabled demand entry. Ordered by
    /// first appearance across placements (bidding before waterfall, in published order) — not by
    /// `connectedNetworks`, whose key order carries no meaning.
    let enabledNetworks: [AdvergicAdNetwork]

    private init(
        platforms: [AdvergicAdNetwork: RemotePlatform],
        placements: [RemotePlacement],
        version: Int,
        declared: Bool
    ) {
        self.platforms = platforms
        self.placements = placements
        self.version = version
        self.declared = declared

        if !declared {
            enabledNetworks = AdvergicAdNetwork.allCases
        } else {
            var seen = Set<AdvergicAdNetwork>()
            enabledNetworks = placements
                .flatMap { $0.bidding + $0.waterfall }
                .filter { $0.enabled && platforms[$0.network] != nil }
                .map(\.network)
                .filter { seen.insert($0).inserted }
        }
    }

    static let empty = RemoteAdsConfig(platforms: [:], placements: [], version: 0, declared: false)

    func platform(_ network: AdvergicAdNetwork) -> RemotePlatform? { platforms[network] }

    /// Why `network` must not be started, or nil when it may be. Surfaced through the slot's
    /// failure callback, so it says which side of the wire decided.
    func gate(_ network: AdvergicAdNetwork) -> String? {
        guard declared else { return nil }
        if platforms[network] == nil {
            return "\(network) is not connected for this app — the SDK will not start it"
        }
        if !enabledNetworks.contains(network) {
            return "\(network) is connected but no placement references it"
        }
        return nil
    }

    /// Placements for `format`, in published order.
    func placements(for format: String) -> [RemotePlacement] {
        placements.filter { $0.format.caseInsensitiveCompare(format) == .orderedSame }
    }

    /// The placement a slot of this shape fills from.
    ///
    /// Sized formats match on the exact shape — every network issues a different ad unit per
    /// banner size. An adaptive placement is the fallback, then an unsized one.
    func placement(for format: String, width: Int? = nil, height: Int? = nil) -> RemotePlacement? {
        let candidates = placements(for: format)
        guard let width, let height else { return candidates.first }

        return candidates.first { $0.matches(width: width, height: height) }
            ?? candidates.first { $0.adaptive }
            ?? candidates.first { $0.width == nil }
    }

    /// The network unnamed slots fill from. Falls back to the first enabled network when the
    /// local default isn't one — the server is authoritative about registrations.
    func defaultNetwork(preferred: AdvergicAdNetwork) -> AdvergicAdNetwork {
        if gate(preferred) == nil { return preferred }

        guard let fallback = enabledNetworks.first else {
            AdvergicLog.w("Config enables no ad network — slots that don't name one cannot fill")
            return preferred
        }
        AdvergicLog.w("Default network \(preferred) is not enabled by config; using \(fallback)")
        return fallback
    }

    var description: String {
        declared
            ? "RemoteAdsConfig(v\(version), \(platforms.values.map(\.description).sorted()), \(placements.count) placements)"
            : "RemoteAdsConfig(no connectedNetworks key — nothing gated)"
    }

    // MARK: Parsing

    /// Matched case-insensitively against the dashboard's network catalog; each network's former
    /// name is accepted too, since back-office records still use them.
    static let networkIds: [String: AdvergicAdNetwork] = [
        "admob": .admobTest,
        "admob_test": .admobTest,
        "yandex": .yandex,
        "pangle": .pangle,
        "liftoff": .liftoff,
        "vungle": .liftoff,
        "meta": .meta,
        "facebook": .meta,
        "inmobi": .inMobi,
        "chartboost": .chartboost,
        "applovin": .appLovin,
        "unityads": .unityAds,
        "unity": .unityAds,
        "ironsource": .ironSource,
        "levelplay": .ironSource,
        "mintegral": .mintegral,
        "bidmachine": .bidMachine,
        "digitalturbine": .digitalTurbine,
        "fyber": .digitalTurbine,
        "fairbid": .digitalTurbine,
    ]

    static func network(forId raw: String) -> AdvergicAdNetwork? {
        networkIds[raw.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Never throws: a config the SDK cannot read must not take the ad stack down. Anything
    /// unparseable degrades to "no opinion".
    static func parse(_ json: [String: Any]) -> RemoteAdsConfig {
        guard let connected = json.object("connectedNetworks") else { return .empty }

        var platforms: [AdvergicAdNetwork: RemotePlatform] = [:]
        for rawId in connected.keys {
            guard let network = network(forId: rawId) else {
                // Expected: the catalog carries networks this SDK build has no adapter for.
                AdvergicLog.d("Ignoring unknown connected network '\(rawId)'")
                continue
            }
            platforms[network] = RemotePlatform(network: network, credentials: connected.stringMap(rawId))
        }

        let mediation = json.object("mediation")
        let placements = (mediation?.array("placements") ?? []).compactMap(parsePlacement)

        return RemoteAdsConfig(
            platforms: platforms,
            placements: placements,
            version: mediation?.int("version") ?? 0,
            declared: true
        )
    }

    private static func parsePlacement(_ value: Any) -> RemotePlacement? {
        guard let entry = value as? [String: Any] else { return nil }
        // An absent format would silently become a banner request against, say, a rewarded
        // unit, so such an entry is dropped instead.
        let format = entry.string("format")
        guard !format.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let size = entry.object("size")
        let width = size.map { $0.int("width") }.flatMap { $0 > 0 ? $0 : nil }
        let height = size.map { $0.int("height") }.flatMap { $0 > 0 ? $0 : nil }

        return RemotePlacement(
            id: entry.string("id"),
            name: entry.string("name"),
            format: format,
            width: width,
            height: height,
            adaptive: entry.bool("adaptive", default: false),
            bidding: (entry.array("bidding") ?? []).compactMap(parseDemand),
            waterfall: (entry.array("waterfall") ?? []).compactMap(parseDemand)
        )
    }

    private static func parseDemand(_ value: Any) -> RemoteDemand? {
        guard let row = value as? [String: Any],
              let network = network(forId: row.string("network"))
        else { return nil }

        let adUnitId = row.string("adUnitId")
        guard !adUnitId.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let floor = row.isNull("floor") ? nil : row.double("floor").flatMap { $0.isNaN ? nil : $0 }

        return RemoteDemand(
            network: network,
            adUnitId: adUnitId,
            label: row.string("label"),
            floor: floor,
            enabled: row.bool("enabled", default: true)
        )
    }
}
