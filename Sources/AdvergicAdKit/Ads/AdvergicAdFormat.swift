import Foundation

/// A fullscreen ad format.
///
/// Separate from `AdvergicAdSize` because the request differs in shape, not just dimensions:
/// these are loaded ahead of time and shown over a view controller at a moment the app chooses.
/// Every network issues a separate ad unit per format.
public enum AdvergicAdFormat: String, CaseIterable, CustomStringConvertible, Sendable {
    /// Fullscreen, dismissible, shown between screens.
    case interstitial = "INTERSTITIAL"

    /// Fullscreen, grants a reward on completion.
    case rewarded = "REWARDED"

    /// Shown at launch or on return to foreground. Expires within a few hours of loading.
    case appOpen = "APP_OPEN"

    public var description: String { rawValue }

    /// The dashboard's format slug — not the case name for app open.
    var configName: String {
        switch self {
        case .interstitial: return "interstitial"
        case .rewarded: return "rewarded"
        case .appOpen: return "app_open"
        }
    }
}
