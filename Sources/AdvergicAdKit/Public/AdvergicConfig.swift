import Foundation

/// Tunables for the SDK. Every value has a sensible default, so most integrations pass
/// `AdvergicConfig()` or omit it entirely.
///
/// Per-network credentials here are **fallbacks**: the dashboard's value, delivered in the config,
/// wins whenever it is present, so a rotated key takes effect without an app release.
public struct AdvergicConfig: Sendable {

    /// Host of the Advergic middleware. Override to aim at a local mock.
    public var baseURL: String

    /// Emits `Advergic` console output. Leave off in release builds. Does **not** affect the
    /// diagnostics AdKit sends to Advergic's collector.
    public var enableLogging: Bool

    /// Connection timeout for middleware calls, in seconds.
    public var connectTimeout: TimeInterval

    /// Overall timeout for a middleware response, in seconds.
    public var readTimeout: TimeInterval

    /// Fallback network, used only when the config carries no placement for a slot's format.
    public var adNetwork: AdvergicAdNetwork

    /// Banner ad unit for `adNetwork` when a slot names none. Empty means the network's default.
    public var bannerAdUnitId: String

    /// Advertising ids (IDFA) or device ids to mark as test devices where a network supports it.
    public var testDeviceAdvertisingIds: [String]

    public var pangleAppId: String
    public var liftoffAppId: String
    public var chartboostAppId: String
    public var inMobiAccountId: String
    public var applovinSdkKey: String
    public var unityGameId: String
    /// Serves Unity test ads. Never ship it true.
    public var unityTestMode: Bool
    public var ironSourceAppKey: String
    public var mintegralAppId: String
    public var mintegralAppKey: String
    public var bidMachineSourceId: String
    /// Serves BidMachine test demand. Never ship it true.
    public var bidMachineTestMode: Bool
    public var digitalTurbineAppId: String

    /// Marks this device a Meta test device regardless of its per-install hash. Never ship it true.
    public var metaTestMode: Bool

    /// Asks Chartboost's partners for test ads — required before release, since Chartboost serves
    /// real demand only to apps live on a store. Never ship it true.
    public var chartboostTestMode: Bool

    /// When true (the default) no ad stack starts until the middleware has returned a config for
    /// this bundle id. Leave it true: false opens the gate before the config lands, so every slot
    /// silently falls back to `adNetwork`.
    public var requireConfigForAds: Bool

    /// How long ads wait for a fresh config before falling back to the last one cached on disk,
    /// in seconds. The fetch is not cancelled; it still lands and refreshes the cache.
    public var configTimeout: TimeInterval

    public init(
        baseURL: String = Constants.baseURL,
        enableLogging: Bool = false,
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval = 15,
        adNetwork: AdvergicAdNetwork = .admobTest,
        bannerAdUnitId: String = "",
        testDeviceAdvertisingIds: [String] = [],
        pangleAppId: String = Constants.pangleAppId,
        liftoffAppId: String = Constants.liftoffAppId,
        chartboostAppId: String = Constants.chartboostAppId,
        inMobiAccountId: String = Constants.inMobiAccountId,
        applovinSdkKey: String = Constants.applovinSdkKey,
        unityGameId: String = Constants.unityGameId,
        unityTestMode: Bool = false,
        ironSourceAppKey: String = Constants.ironSourceAppKey,
        mintegralAppId: String = Constants.mintegralAppId,
        mintegralAppKey: String = Constants.mintegralAppKey,
        bidMachineSourceId: String = Constants.bidMachineSourceId,
        bidMachineTestMode: Bool = false,
        digitalTurbineAppId: String = Constants.digitalTurbineAppId,
        metaTestMode: Bool = false,
        chartboostTestMode: Bool = false,
        requireConfigForAds: Bool = true,
        configTimeout: TimeInterval = 2.5
    ) {
        self.baseURL = baseURL
        self.enableLogging = enableLogging
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.adNetwork = adNetwork
        self.bannerAdUnitId = bannerAdUnitId
        self.testDeviceAdvertisingIds = testDeviceAdvertisingIds
        self.pangleAppId = pangleAppId
        self.liftoffAppId = liftoffAppId
        self.chartboostAppId = chartboostAppId
        self.inMobiAccountId = inMobiAccountId
        self.applovinSdkKey = applovinSdkKey
        self.unityGameId = unityGameId
        self.unityTestMode = unityTestMode
        self.ironSourceAppKey = ironSourceAppKey
        self.mintegralAppId = mintegralAppId
        self.mintegralAppKey = mintegralAppKey
        self.bidMachineSourceId = bidMachineSourceId
        self.bidMachineTestMode = bidMachineTestMode
        self.digitalTurbineAppId = digitalTurbineAppId
        self.metaTestMode = metaTestMode
        self.chartboostTestMode = chartboostTestMode
        self.requireConfigForAds = requireConfigForAds
        self.configTimeout = configTimeout
    }

    /// The banner ad unit for `network`. `bannerAdUnitId` overrides only the configured network,
    /// so a slot naming a different one doesn't inherit it.
    func resolvedBannerAdUnitId(_ network: AdvergicAdNetwork, size: AdvergicAdSize = .banner) -> String {
        if !bannerAdUnitId.trimmingCharacters(in: .whitespaces).isEmpty, network == adNetwork {
            return bannerAdUnitId
        }
        let mrec = size == .mediumRectangle
        switch network {
        case .admobTest: return Constants.admobTestBannerAdUnitId
        case .yandex: return Constants.yandexBannerAdUnitId
        case .pangle: return mrec ? Constants.pangleMrecSlotId : Constants.pangleBannerSlotId
        case .meta: return mrec ? Constants.metaMrecPlacementId : Constants.metaBannerPlacementId
        case .chartboost: return Constants.chartboostBannerPlacement
        case .inMobi: return mrec ? Constants.inMobiMrecPlacementId : Constants.inMobiBannerPlacementId
        case .liftoff: return mrec ? Constants.liftoffMrecPlacementId : Constants.liftoffBannerPlacementId
        case .appLovin: return mrec ? Constants.applovinMrecAdUnitId : Constants.applovinBannerAdUnitId
        case .unityAds: return Constants.unityBannerPlacementId
        case .ironSource: return Constants.ironSourceBannerAdUnitId
        case .mintegral: return Constants.mintegralBannerUnitId
        case .bidMachine: return Constants.bidMachineBannerPlacement
        case .digitalTurbine: return Constants.digitalTurbineBannerPlacement
        }
    }

    /// The fullscreen ad unit for `network` at `format`. Never falls back to a banner unit: every
    /// network issues a distinct unit per format, and a banner id could only be rejected.
    func resolvedFullscreenAdUnitId(_ network: AdvergicAdNetwork, format: AdvergicAdFormat) -> String {
        func pick(_ interstitial: String, _ rewarded: String, _ appOpen: String) -> String {
            switch format {
            case .interstitial: return interstitial
            case .rewarded: return rewarded
            case .appOpen: return appOpen
            }
        }
        let noAppOpen = "REPLACE_WITH_\(network.name)_APP_OPEN"
        switch network {
        case .admobTest:
            return pick(Constants.admobTestInterstitialAdUnitId, Constants.admobTestRewardedAdUnitId,
                        Constants.admobTestAppOpenAdUnitId)
        case .yandex:
            return pick(Constants.yandexInterstitialAdUnitId, Constants.yandexRewardedAdUnitId,
                        Constants.yandexAppOpenAdUnitId)
        case .pangle:
            return pick(Constants.pangleInterstitialSlotId, Constants.pangleRewardedSlotId,
                        Constants.pangleAppOpenSlotId)
        case .meta:
            return pick(Constants.metaInterstitialPlacementId, Constants.metaRewardedPlacementId,
                        Constants.metaAppOpenPlacementId)
        case .liftoff:
            return pick(Constants.liftoffInterstitialPlacementId, Constants.liftoffRewardedPlacementId,
                        Constants.liftoffAppOpenPlacementId)
        case .inMobi:
            return pick(Constants.inMobiInterstitialPlacementId, Constants.inMobiRewardedPlacementId,
                        noAppOpen)
        case .chartboost:
            return pick(Constants.chartboostInterstitialPlacement, Constants.chartboostRewardedPlacement,
                        Constants.chartboostAppOpenPlacement)
        case .appLovin:
            return pick(Constants.applovinInterstitialAdUnitId, Constants.applovinRewardedAdUnitId,
                        Constants.applovinAppOpenAdUnitId)
        case .unityAds:
            return pick(Constants.unityInterstitialPlacementId, Constants.unityRewardedPlacementId,
                        noAppOpen)
        case .ironSource:
            return pick(Constants.ironSourceInterstitialAdUnitId, Constants.ironSourceRewardedAdUnitId,
                        noAppOpen)
        case .mintegral:
            return pick(Constants.mintegralInterstitialUnitId, Constants.mintegralRewardedUnitId,
                        noAppOpen)
        case .bidMachine:
            return pick(Constants.bidMachineInterstitialPlacement, Constants.bidMachineRewardedPlacement,
                        noAppOpen)
        case .digitalTurbine:
            return pick(Constants.digitalTurbineInterstitialPlacement,
                        Constants.digitalTurbineRewardedPlacement, noAppOpen)
        }
    }

    /// The native ad unit for `network`. Native takes no size: the assets set the shape.
    func resolvedNativeAdUnitId(_ network: AdvergicAdNetwork) -> String {
        switch network {
        case .admobTest: return Constants.admobTestNativeAdUnitId
        case .yandex: return Constants.yandexNativeAdUnitId
        case .pangle: return Constants.pangleNativeSlotId
        case .meta: return Constants.metaNativePlacementId
        case .liftoff: return Constants.liftoffNativePlacementId
        case .inMobi: return Constants.inMobiNativePlacementId
        case .appLovin: return Constants.applovinNativeAdUnitId
        default: return "REPLACE_WITH_\(network.name)_NATIVE_AD_UNIT_ID"
        }
    }
}

extension AdvergicConfig: CustomStringConvertible {
    public var description: String {
        "AdvergicConfig(baseURL=\(baseURL), enableLogging=\(enableLogging), " +
            "connectTimeout=\(connectTimeout), readTimeout=\(readTimeout), " +
            "adNetwork=\(adNetwork), bannerAdUnitId=\(resolvedBannerAdUnitId(adNetwork)), " +
            "testDeviceAdvertisingIds=\(testDeviceAdvertisingIds.count))"
    }
}
