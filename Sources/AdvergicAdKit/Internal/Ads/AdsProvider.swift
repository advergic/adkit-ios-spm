import Foundation

/// Builds and caches the per-network ad machinery.
///
/// Networks are created lazily, which is also what keeps one the publisher never registered with
/// from starting: nothing here runs until a slot asks, and `remoteAds` decides whether it may.
final class AdsProvider {

    let config: AdvergicConfig
    private let initializers = Locked<[AdvergicAdNetwork: AdvergicAdsInitializer]>([:])

    /// The server's platform list. Nil until the config lands, and forever when the publisher
    /// opted out of the config check — both mean "start whatever is asked for".
    private let remote = Locked<RemoteAdsConfig?>(nil)

    init(config: AdvergicConfig) {
        self.config = config
    }

    /// Must land **before** `AdsRegistry.markConfigReady()`: initializers are cached on first
    /// use, so one built before the gates were in place would keep serving a disabled network.
    func applyRemoteConfig(_ remoteAds: RemoteAdsConfig) {
        remote.set(remoteAds)
        // Learned prices outrank floors, so the store must be readable before the first auction.
        AdPriceHistory.attach()
        AdvergicLog.d("Ad networks enabled by config: \(remoteAds.enabledNetworks)")
    }

    var remoteAds: RemoteAdsConfig? { remote.get() }

    func initializer(_ network: AdvergicAdNetwork) -> AdvergicAdsInitializer {
        if let existing = initializers.get()[network] { return existing }
        let created = create(network)
        return initializers.mutate { cache in
            if let raced = cache[network] { return raced }
            cache[network] = created
            return created
        }
    }

    /// A gated network gets a `DisabledAdsInitializer` — checked before any credential is read.
    private func create(_ network: AdvergicAdNetwork) -> AdvergicAdsInitializer {
        if let reason = remote.get()?.gate(network) {
            return DisabledAdsInitializer(networkName: network.name, reason: reason)
        }
        guard let adapter = AdapterDiscovery.adapter(for: network) else {
            return DisabledAdsInitializer(
                networkName: network.name,
                reason: AdapterDiscovery.notInstalledMessage(network)
            )
        }
        let setup = AdvergicNetworkSetup(network: network, config: config, platform: remote.get()?.platform(network))
        return adapter.makeInitializer(setup: setup)
    }

    // MARK: Chains

    /// The chain for a banner of this size. Nil when no config has landed or it holds no
    /// placement of that shape — the caller falls back to the single configured network.
    func bannerChain(size: AdvergicAdSize) async -> AdChain? {
        guard let placement = remote.get()?.placement(for: "banner", width: size.width, height: size.height)
        else { return nil }
        return await chain(placement, request: "banner \(size)", size: size)
    }

    /// Fullscreen placements carry no size — the format alone identifies them.
    func fullscreenChain(format: AdvergicAdFormat) async -> AdChain? {
        guard let placement = remote.get()?.placement(for: format.configName) else { return nil }
        return await chain(placement, request: format.configName, size: nil)
    }

    func nativeChain() async -> AdChain? {
        guard let placement = remote.get()?.placement(for: "native") else { return nil }
        return await chain(placement, request: "native", size: nil)
    }

    private func chain(_ placement: RemotePlacement, request: String, size: AdvergicAdSize?) async -> AdChain {
        let rungs = await AdAuction.resolve(entries: placement.candidates(), size: size, placement: placement.name)
        return AdChain(placementName: placement.name, rungs: rungs, request: request)
    }

    // MARK: Pinned-slot ids

    func bannerAdUnitId(_ network: AdvergicAdNetwork, size: AdvergicAdSize) -> String {
        config.resolvedBannerAdUnitId(network, size: size)
    }

    func fullscreenAdUnitId(_ network: AdvergicAdNetwork, format: AdvergicAdFormat) -> String {
        config.resolvedFullscreenAdUnitId(network, format: format)
    }

    func nativeAdUnitId(_ network: AdvergicAdNetwork) -> String {
        config.resolvedNativeAdUnitId(network)
    }
}

#if canImport(UIKit)
extension AdsProvider {
    func bannerAdapter(_ network: AdvergicAdNetwork) -> AdvergicBannerAdapter {
        AdapterDiscovery.adapter(for: network)?.makeBannerAdapter() ?? MissingAdapter(network: network)
    }

    func fullscreenAdapter(_ network: AdvergicAdNetwork) -> AdvergicFullscreenAdapter {
        AdapterDiscovery.adapter(for: network)?.makeFullscreenAdapter() ?? MissingFullscreenAdapter(network: network)
    }

    func nativeAdapter(_ network: AdvergicAdNetwork) -> AdvergicNativeAdapter {
        AdapterDiscovery.adapter(for: network)?.makeNativeAdapter() ?? MissingAdapter(network: network)
    }
}
#endif
