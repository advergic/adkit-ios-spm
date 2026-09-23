import Foundation
import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

/// Scripted HTTP: returns `response` (or throws `error`) after `delay`, recording every request.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    var response = HTTPResponse(statusCode: 200, body: "{}")
    var error: Error?
    var delay: TimeInterval = 0

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    init(status: Int = 200, body: String? = "{}") {
        response = HTTPResponse(statusCode: status, body: body)
    }

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); _requests.append(request); lock.unlock()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        return response
    }
}

final class MemoryConfigCache: ConfigCache {
    var stored: AdvergicRemoteConfig?
    private(set) var cleared = 0
    private(set) var saved = 0

    init(_ raw: String? = nil) {
        stored = raw.flatMap(AdvergicRemoteConfig.parse)
    }

    func load() -> AdvergicRemoteConfig? { stored }
    func save(_ config: AdvergicRemoteConfig) { stored = config; saved += 1 }
    func clear() { stored = nil; cleared += 1 }
}

/// Collects every payload a sender hands over.
final class CapturingTransport: LogTransport {
    private let lock = NSLock()
    private var _payloads: [Data] = []
    var fail = false

    var payloads: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _payloads
    }

    func send(_ payload: Data, completion: @escaping (Bool) -> Void) {
        lock.lock(); _payloads.append(payload); lock.unlock()
        completion(!fail)
    }

    func json(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: payloads[index])) as? [String: Any] ?? [:]
    }
}

func parseJSON(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

/// Drains the main queue so work posted with `MainThread.post` from a background thread has run.
func drainMainQueue() {
    let done = XCTestExpectation(description: "main queue drained")
    DispatchQueue.main.async { done.fulfill() }
    _ = XCTWaiter.wait(for: [done], timeout: 2)
}
