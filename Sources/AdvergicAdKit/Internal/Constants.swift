import Foundation

/// Build-time constants for the middleware contract, and the default ad unit ids used when a
/// slot pins a network the config does not describe.
///
/// **Ad unit ids are per platform on every network.** None of the Android SDK's values can be
/// reused here except where noted — an Android slot id is rejected by the iOS SDK of the same
/// network, and the rejection reads like a no-fill.
@usableFromInline
enum Constants {

    static let sdkVersion = "0.1.2"

    /// Selects the environment for every Advergic endpoint at once.
    @usableFromInline static let isDevMode = false

    @usableFromInline static let devHost = "https://devrack.avads.live"
    @usableFromInline static let prodHost = "https://rack.avads.live"

    /// Resolved host for the current environment.
    @usableFromInline static var baseURL: String { isDevMode ? devHost : prodHost }

    /// Observability collector, shared with the other Advergic SDKs. One host for both
    /// environments, told apart by the `deployment.environment` resource attribute.
    static let otelEndpoint = "https://observe.avads.live"

    /// OTLP/HTTP JSON logs route on `otelEndpoint`.
    static let otelLogsPath = "/logs/otlp/v1/logs"

    /// Events collection route on `baseURL`.
    static let eventsPath = "/sdk/collect"

    /// Analytics endpoint: follows `isDevMode` like the config call, so a release build never
    /// reports production impressions into the development collector.
    static var eventsEndpoint: String { baseURL + eventsPath }

    /// Always over HTTPS — the host answers this route only on TLS.
    static let configPath = "/config/mediation/config"

    // MARK: Wire headers
    // The config call carries no body and no query params; these headers are everything the
    // server needs.

    static let headerTimestamp = "timestamp"
    static let headerSignature = "signature"
    static let headerBundleId = "bundle-id"

    /// Not part of the HMAC. Lets the middleware tell an iOS build from an Android one that
    /// shares its bundle id — ad unit ids are per platform. See PLAN.md, Q1.
    static let headerPlatform = "platform"
    static let platformValue = "ios"

    // MARK: AdMob
    // Google's published iOS test identifiers — distinct from the Android ones. They fill on any
    // device with no account.

    static let admobTestAppId = "ca-app-pub-3940256099942544~1458002511"
    static let admobTestBannerAdUnitId = "ca-app-pub-3940256099942544/2934735716"
    static let admobTestInterstitialAdUnitId = "ca-app-pub-3940256099942544/4411468910"
    static let admobTestRewardedAdUnitId = "ca-app-pub-3940256099942544/1712485313"
    static let admobTestAppOpenAdUnitId = "ca-app-pub-3940256099942544/5575463023"
    static let admobTestNativeAdUnitId = "ca-app-pub-3940256099942544/3986624511"

    // MARK: Yandex
    // Yandex takes no app id; the ad unit encodes it. The Android app's real units
    // (R-M-19736270-*) belong to an Android app, so the iOS defaults are Yandex's public demo
    // units until an iOS app is registered.

    static let yandexBannerAdUnitId = "demo-banner-yandex"
    static let yandexInterstitialAdUnitId = "demo-interstitial-yandex"
    static let yandexRewardedAdUnitId = "demo-rewarded-yandex"
    static let yandexAppOpenAdUnitId = "demo-appopenad-yandex"
    static let yandexNativeAdUnitId = "demo-native-app-yandex"

    // MARK: Pangle
    // Issued per platform. No iOS app has been registered yet.

    @usableFromInline static let pangleAppId = "REPLACE_WITH_PANGLE_IOS_APP_ID"
    static let pangleBannerSlotId = "REPLACE_WITH_PANGLE_IOS_BANNER"
    static let pangleMrecSlotId = "REPLACE_WITH_PANGLE_IOS_MREC"
    static let pangleInterstitialSlotId = "REPLACE_WITH_PANGLE_IOS_INTERSTITIAL"
    static let pangleRewardedSlotId = "REPLACE_WITH_PANGLE_IOS_REWARDED"
    static let pangleAppOpenSlotId = "REPLACE_WITH_PANGLE_IOS_APP_OPEN"
    static let pangleNativeSlotId = "REPLACE_WITH_PANGLE_IOS_NATIVE"

    // MARK: Liftoff Monetize (Vungle)
    // App ids and placements are per platform. Placements must be non-bidding, as on Android.

    @usableFromInline static let liftoffAppId = "REPLACE_WITH_LIFTOFF_IOS_APP_ID"
    static let liftoffBannerPlacementId = "REPLACE_WITH_LIFTOFF_IOS_BANNER"
    static let liftoffMrecPlacementId = "REPLACE_WITH_LIFTOFF_IOS_MREC"
    static let liftoffInterstitialPlacementId = "REPLACE_WITH_LIFTOFF_IOS_INTERSTITIAL"
    static let liftoffRewardedPlacementId = "REPLACE_WITH_LIFTOFF_IOS_REWARDED"
    static let liftoffAppOpenPlacementId = "REPLACE_WITH_LIFTOFF_IOS_APP_OPEN"
    static let liftoffNativePlacementId = "REPLACE_WITH_LIFTOFF_IOS_NATIVE"

    // MARK: Chartboost Mediation

    @usableFromInline static let chartboostAppId = "REPLACE_WITH_CHARTBOOST_IOS_APP_ID"
    static let chartboostBannerPlacement = "REPLACE_WITH_CHARTBOOST_IOS_BANNER"
    static let chartboostInterstitialPlacement = "REPLACE_WITH_CHARTBOOST_IOS_INTERSTITIAL"
    static let chartboostRewardedPlacement = "REPLACE_WITH_CHARTBOOST_IOS_REWARDED"
    /// Chartboost has no app-open format.
    static let chartboostAppOpenPlacement = "REPLACE_WITH_CHARTBOOST_APP_OPEN"

    // MARK: InMobi
    /// Account-level, so shared with Android. Placements are per app and therefore per platform.
    @usableFromInline static let inMobiAccountId = "e64c1b97fbb04ae8ba5adc1f4e9323f6"
    static let inMobiBannerPlacementId = "REPLACE_WITH_INMOBI_IOS_BANNER"
    static let inMobiMrecPlacementId = "REPLACE_WITH_INMOBI_IOS_MREC"
    static let inMobiInterstitialPlacementId = "REPLACE_WITH_INMOBI_IOS_INTERSTITIAL"
    static let inMobiRewardedPlacementId = "REPLACE_WITH_INMOBI_IOS_REWARDED"
    static let inMobiNativePlacementId = "REPLACE_WITH_INMOBI_IOS_NATIVE"

    // MARK: Meta Audience Network
    // `<appId>_<placementId>`. Meta placements belong to a property that spans platforms, and
    // these were exercised from the iOS simulator during Android bring-up (see the test hash
    // below), so they are shared.

    static let metaBannerPlacementId = "1413796817472685_1413797700805930"
    static let metaMrecPlacementId = "1413796817472685_1413797697472597"
    static let metaInterstitialPlacementId = "1413796817472685_1413797687472598"
    /// Rewarded interstitial — Meta has no plain rewarded format.
    static let metaRewardedPlacementId = "1413796817472685_1413797694139264"
    static let metaNativePlacementId = "1413796817472685_1413797684139265"
    /// Meta has no app-open format.
    static let metaAppOpenPlacementId = "REPLACE_WITH_META_APP_OPEN"

    /// Devices Meta serves test ads to. Hashes are per install; prefer `metaTestMode`.
    static let metaTestDeviceHashes: [String] = [
        // iOS simulator.
        "b602d594afd2b0b327e07a06f36ca6a7e42546d0",
    ]

    // MARK: AppLovin MAX

    @usableFromInline static let applovinSdkKey = "REPLACE_WITH_APPLOVIN_SDK_KEY"
    static let applovinBannerAdUnitId = "REPLACE_WITH_APPLOVIN_BANNER"
    static let applovinMrecAdUnitId = "REPLACE_WITH_APPLOVIN_MREC"
    static let applovinInterstitialAdUnitId = "REPLACE_WITH_APPLOVIN_INTERSTITIAL"
    static let applovinRewardedAdUnitId = "REPLACE_WITH_APPLOVIN_REWARDED"
    static let applovinAppOpenAdUnitId = "REPLACE_WITH_APPLOVIN_APP_OPEN"
    static let applovinNativeAdUnitId = "REPLACE_WITH_APPLOVIN_NATIVE"

    // MARK: Unity Ads
    /// Issued per platform; the wrong one initializes cleanly and never fills.
    @usableFromInline static let unityGameId = "REPLACE_WITH_UNITY_IOS_GAME_ID"
    // Unity creates these on every new project; the iOS names differ from Android's.
    static let unityBannerPlacementId = "Banner_iOS"
    static let unityInterstitialPlacementId = "Interstitial_iOS"
    static let unityRewardedPlacementId = "Rewarded_iOS"

    // MARK: ironSource (LevelPlay)

    @usableFromInline static let ironSourceAppKey = "REPLACE_WITH_IRONSOURCE_APP_KEY"
    static let ironSourceBannerAdUnitId = "REPLACE_WITH_IRONSOURCE_BANNER"
    static let ironSourceInterstitialAdUnitId = "REPLACE_WITH_IRONSOURCE_INTERSTITIAL"
    static let ironSourceRewardedAdUnitId = "REPLACE_WITH_IRONSOURCE_REWARDED"

    // MARK: Mintegral
    // Two credentials, and two ids per ad travelling as "placementId/unitId".

    @usableFromInline static let mintegralAppId = "REPLACE_WITH_MINTEGRAL_APP_ID"
    @usableFromInline static let mintegralAppKey = "REPLACE_WITH_MINTEGRAL_APP_KEY"
    static let mintegralBannerUnitId = "REPLACE_WITH_MINTEGRAL_BANNER"
    static let mintegralInterstitialUnitId = "REPLACE_WITH_MINTEGRAL_INTERSTITIAL"
    static let mintegralRewardedUnitId = "REPLACE_WITH_MINTEGRAL_REWARDED"

    // MARK: BidMachine
    @usableFromInline static let bidMachineSourceId = "REPLACE_WITH_BIDMACHINE_SOURCE_ID"
    /// Optional: a request without a placement still runs the auction.
    static let bidMachineBannerPlacement = ""
    static let bidMachineInterstitialPlacement = ""
    static let bidMachineRewardedPlacement = ""

    // MARK: Digital Turbine (FairBid)
    @usableFromInline static let digitalTurbineAppId = "REPLACE_WITH_DIGITAL_TURBINE_APP_ID"
    static let digitalTurbineBannerPlacement = "REPLACE_WITH_DT_BANNER"
    static let digitalTurbineInterstitialPlacement = "REPLACE_WITH_DT_INTERSTITIAL"
    static let digitalTurbineRewardedPlacement = "REPLACE_WITH_DT_REWARDED"

    static let logTag = "Advergic"
}
