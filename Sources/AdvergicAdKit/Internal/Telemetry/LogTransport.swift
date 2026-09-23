import Foundation

/// Where an encoded batch goes. Swapped out in tests so nothing reaches the network.
protocol LogTransport: AnyObject {
    /// Fire and forget. `completion` reports whether the collector accepted the batch.
    func send(_ payload: Data, completion: @escaping (Bool) -> Void)
}

/// Discards everything.
final class NoLogTransport: LogTransport {
    func send(_ payload: Data, completion: @escaping (Bool) -> Void) { completion(true) }
}

/// Posts JSON to a collector.
///
/// Failures are swallowed and logged once to the console — deliberately not through
/// `AdvergicLog`, which the integrator may have silenced, and never retried: there is nowhere to
/// report a reporting failure to.
final class HTTPLogTransport: LogTransport {

    private let endpoint: URL?
    private let session: URLSession

    init(endpoint: String) {
        self.endpoint = URL(string: endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ payload: Data, completion: @escaping (Bool) -> Void) {
        guard let endpoint else { completion(false); return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        session.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("[Advergic] Telemetry send failed: %@", error.localizedDescription)
                completion(false)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let accepted = (200...299).contains(status)
            if !accepted { NSLog("[Advergic] Telemetry rejected with HTTP %d", status) }
            completion(accepted)
        }.resume()
    }
}
