import Foundation

/// Wall clock, injected so signature and cache-age tests are deterministic.
struct Clock {
    let now: () -> Date

    var nowEpochSeconds: Int64 { Int64(now().timeIntervalSince1970) }
    var nowEpochMillis: Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded()) }

    static let system = Clock(now: Date.init)
}

/// Lower-case hex, the encoding the middleware expects for the signature.
enum Hex {
    static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal lock-protected box for state touched from several threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); value = newValue; lock.unlock()
    }

    @discardableResult
    func mutate<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
