import Foundation
import os.log

/// Console wrapper that stays silent unless the integrator opts in.
///
/// Uses `os_log` so output lands in Console.app and Xcode alike, filterable on the `Advergic`
/// category. Messages are marked public: they carry ad unit ids and network errors, which is the
/// whole point of turning logging on, and a private message renders as `<private>` off-device.
enum AdvergicLog {

    private static let lock = NSLock()
    private static var _enabled = false

    static var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    private static let log = OSLog(subsystem: "com.advergic.adkit", category: Constants.logTag)

    static func d(_ message: @autoclosure () -> String) {
        write(.debug, message)
    }

    /// Outcomes worth keeping when debug output is filtered out — the auction winner line.
    static func i(_ message: @autoclosure () -> String) {
        write(.info, message)
    }

    static func w(_ message: @autoclosure () -> String) {
        write(.default, message)
    }

    static func e(_ message: @autoclosure () -> String) {
        write(.error, message)
    }

    /// Keeps API keys and tokens out of the console.
    static func redact(_ secret: String) -> String {
        secret.count <= 8 ? "***" : "\(secret.prefix(4))***\(secret.suffix(4))"
    }

    private static func write(_ type: OSLogType, _ message: () -> String) {
        guard enabled else { return }
        os_log("%{public}@", log: log, type: type, message())
    }
}
