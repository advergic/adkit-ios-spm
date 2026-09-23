import Foundation

/// Forwards impression revenue to the publisher's MMP.
protocol MmpReporter: AnyObject {
    /// Called once, on the main thread, before any revenue is reported.
    func start()

    /// - Parameter format: Dashboard slug of the ad that earned (`banner`, `rewarded`, …), so the
    ///   reporter can honour the config's format filter.
    func report(_ revenue: AdvergicAdRevenue, format: String)
}

/// No MMP connected, or one this build has no integration for.
final class NoMmpReporter: MmpReporter {
    func start() {}
    func report(_ revenue: AdvergicAdRevenue, format: String) {}
}

/// An MMP the publisher connected, as handed to its module.
@_spi(AdvergicAdapters)
public struct AdvergicMmpConnection {
    let mmp: RemoteMmp

    public var id: String { mmp.id }
    public var formatsDescription: String { mmp.formatsDescription }
    public func credential(_ key: String) -> String? { mmp.credential(key) }
    /// Honour this exactly: a publisher who connected an MMP for `rewarded` only gets rewarded
    /// revenue forwarded.
    public func reports(format: String) -> Bool { mmp.reports(format: format) }
}

/// Implemented once per MMP module, exported under the Objective-C name `MmpFactory` looks for.
/// Must never throw or crash: attribution is reporting, ads are revenue.
@_spi(AdvergicAdapters)
public protocol AdvergicMmpReporter: NSObject {
    init(connection: AdvergicMmpConnection)
    func start()
    func report(_ revenue: AdvergicAdRevenue, format: String)
}

private final class ModuleReporter: MmpReporter {
    let module: AdvergicMmpReporter
    init(_ module: AdvergicMmpReporter) { self.module = module }
    func start() { module.start() }
    func report(_ revenue: AdvergicAdRevenue, format: String) { module.report(revenue, format: format) }
}

/// Fans an impression out to every connected MMP. One failing must not stop the others.
private final class FanoutReporter: MmpReporter {
    let reporters: [MmpReporter]
    init(_ reporters: [MmpReporter]) { self.reporters = reporters }

    func start() { reporters.forEach { $0.start() } }

    func report(_ revenue: AdvergicAdRevenue, format: String) {
        reporters.forEach { $0.report(revenue, format: format) }
    }
}

enum MmpFactory {

    static func className(for id: String) -> String? {
        switch id {
        case "appsflyer": return "AdvergicAppsFlyerReporter"
        case "singular": return "AdvergicSingularReporter"
        case "adjust": return "AdvergicAdjustReporter"
        // Analytics rather than attribution, usually run alongside one of the above.
        case "firebase", "firebase_analytics", "google_analytics": return "AdvergicFirebaseReporter"
        default: return nil
        }
    }

    /// Test hook: reporters to use instead of runtime lookup, keyed by MMP id.
    static let overrides = Locked<[String: (AdvergicMmpConnection) -> AdvergicMmpReporter]>([:])

    /// A reporter covering every entry, or a no-op when there is nothing to report to. An MMP
    /// this build does not integrate — or whose module isn't linked — is logged and ignored: the
    /// dashboard catalog can list one before an SDK release supports it.
    static func create(_ mmps: [RemoteMmp]) -> MmpReporter {
        let reporters: [MmpReporter] = mmps.compactMap { mmp in
            let connection = AdvergicMmpConnection(mmp: mmp)
            if let override = overrides.get()[mmp.id] {
                return ModuleReporter(override(connection))
            }
            guard let name = className(for: mmp.id) else {
                AdvergicLog.d("MMP '\(mmp.id)' is not integrated in this SDK build")
                return nil
            }
            guard let type = NSClassFromString(name) as? AdvergicMmpReporter.Type else {
                AdvergicLog.w("MMP '\(mmp.id)' is connected but its module is not installed — " +
                              "add the AdvergicAdKit\(name.replacingOccurrences(of: "Advergic", with: "").replacingOccurrences(of: "Reporter", with: "")) product")
                return nil
            }
            return ModuleReporter(type.init(connection: connection))
        }

        switch reporters.count {
        case 0: return NoMmpReporter()
        case 1: return reporters[0]
        default: return FanoutReporter(reporters)
        }
    }
}
