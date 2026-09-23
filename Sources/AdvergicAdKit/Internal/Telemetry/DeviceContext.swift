import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

/// Describes the device and app a batch of telemetry came from.
///
/// These go in the resource/context block rather than on every record: they are fixed for the
/// session. Everything is read defensively — a missing value degrades to a missing attribute.
enum DeviceContext {

    /// The advertising id, and whether the user declined tracking.
    ///
    /// `id` is nil unless App Tracking Transparency is `.authorized`. The all-zero IDFA iOS
    /// returns otherwise is not an identifier, and forwarding it would look like one.
    struct AdvertisingInfo: Equatable {
        let id: String?
        let limitAdTracking: Bool
    }

    /// Device and app facts. Cheap, synchronous.
    static func staticAttributes(bundle: Bundle = .main) -> Attributes {
        var attributes: Attributes = [
            "sdk.name": "advkit-ios",
            "sdk.version": .string(Constants.sdkVersion),
            "device.manufacturer": "Apple",
            "device.brand": "Apple",
            "device.model": .string(modelIdentifier()),
            "device.is_emulator": .bool(isSimulator),
            "device.locale": .string(Locale.current.identifier),
            "device.timezone": .string(TimeZone.current.identifier),
        ]

        #if canImport(UIKit)
        attributes["os.name"] = .string(UIDevice.current.systemName)
        attributes["os.version"] = .string(UIDevice.current.systemVersion)
        let screen = UIScreen.main.nativeBounds
        attributes["device.screen.width_px"] = .int(Int64(screen.width))
        attributes["device.screen.height_px"] = .int(Int64(screen.height))
        attributes["device.screen.scale"] = .double(Double(UIScreen.main.nativeScale))
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        attributes["os.name"] = "macOS"
        attributes["os.version"] = .string("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        #endif

        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            attributes["app.version"] = .string(version)
        }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            // Numeric like Android's versionCode when it parses, so the two can be compared.
            attributes["app.build"] = Int64(build).map(AttributeValue.int) ?? .string(build)
        }

        if let connection = Connectivity.shared.connectionType {
            attributes["network.connection.type"] = .string(connection)
        }
        // No carrier: CTCarrier is deprecated and returns placeholder values on iOS 16+.
        return attributes
    }

    /// Whether the IDFA itself may be sent. Off until PLAN.md Q2 is decided: sending it makes
    /// our collectors tracking domains, which iOS then blocks for every user who declines ATT.
    static let collectsAdvertisingId = false

    /// Reads the ATT status (and, if allowed, the IDFA) without ever prompting. Tracking consent
    /// is the host app's to ask.
    static func advertisingInfo() -> AdvertisingInfo {
        #if canImport(AdSupport) && canImport(UIKit)
        let authorized: Bool
        if #available(iOS 14, *) {
            #if canImport(AppTrackingTransparency)
            authorized = ATTrackingManager.trackingAuthorizationStatus == .authorized
            #else
            authorized = false
            #endif
        } else {
            authorized = ASIdentifierManager.shared().isAdvertisingTrackingEnabled
        }
        guard authorized else { return AdvertisingInfo(id: nil, limitAdTracking: true) }
        guard collectsAdvertisingId else { return AdvertisingInfo(id: nil, limitAdTracking: false) }

        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return AdvertisingInfo(id: id == zeroId ? nil : id, limitAdTracking: false)
        #else
        return AdvertisingInfo(id: nil, limitAdTracking: true)
        #endif
    }

    /// e.g. `iPhone15,2` — the marketing name is not available without a lookup table, and the
    /// identifier is what distinguishes hardware revisions.
    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    /// Simulator traffic is real traffic to an ad network but noise in revenue reporting.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static let zeroId = "00000000-0000-0000-0000-000000000000"
}

/// Tracks the current connection type without blocking anyone who asks.
final class Connectivity: @unchecked Sendable {

    static let shared = Connectivity()

    private let monitor = NWPathMonitor()
    private let current = Locked<String?>(nil)

    private init() {
        monitor.pathUpdateHandler = { [current] path in
            let type: String
            if path.status != .satisfied {
                type = "none"
            } else if path.usesInterfaceType(.wifi) {
                type = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                type = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                type = "ethernet"
            } else {
                type = "other"
            }
            current.set(type)
        }
        monitor.start(queue: DispatchQueue(label: "com.advergic.adkit.connectivity"))
    }

    /// Nil until the monitor has reported once — usually within milliseconds of first use.
    var connectionType: String? { current.get() }
}
