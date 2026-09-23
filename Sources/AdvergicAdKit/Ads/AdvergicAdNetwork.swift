import Foundation

/// Which ad stack fills a slot.
///
/// Apps normally never name one: the published config decides. Naming a network pins a slot to
/// it, which is the diagnostic path.
public enum AdvergicAdNetwork: String, CaseIterable, CustomStringConvertible, Sendable {

    /// Google Mobile Ads. Defaults to Google's public test ids, so it fills with no account.
    /// Revenue arrives on the paid-event handler.
    case admobTest = "ADMOB_TEST"

    /// Yandex Mobile Ads. Takes no app id — the ad unit encodes it. Revenue arrives as the
    /// impression data JSON.
    case yandex = "YANDEX"

    /// Pangle. A demand source that discloses no price, so fills report `revenueUnavailable`.
    case pangle = "PANGLE"

    /// Liftoff Monetize (formerly Vungle). Discloses no price.
    case liftoff = "LIFTOFF"

    /// Meta Audience Network. A plain fill discloses no price; register an
    /// `AdvergicMetaBidProvider` to run an auction first.
    case meta = "META"

    /// InMobi. Discloses the winning bid on each fill.
    case inMobi = "INMOBI"

    /// Chartboost Mediation. A mediator: revenue arrives on its impression-level observer.
    case chartboost = "CHARTBOOST"

    /// AppLovin MAX. A mediator; revenue arrives per ad, always in USD.
    case appLovin = "APPLOVIN"

    /// Unity Ads. Discloses no price. No app-open, no native.
    case unityAds = "UNITY_ADS"

    /// ironSource LevelPlay. A mediator; revenue arrives on a process-wide impression listener.
    case ironSource = "IRONSOURCE"

    /// Mintegral. Discloses no price. Two credentials, two ids per ad.
    case mintegral = "MINTEGRAL"

    /// BidMachine. An exchange: every fill carries its clearing price.
    case bidMachine = "BIDMACHINE"

    /// Digital Turbine FairBid. A mediator that names its own currency.
    case digitalTurbine = "DIGITAL_TURBINE"

    /// The same identifier the Android SDK uses, so telemetry and logs read identically.
    public var name: String { rawValue }

    public var description: String { rawValue }
}
