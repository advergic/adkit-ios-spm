import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HTTPRequest {
    let method: String
    let url: String
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse {
    let statusCode: Int
    let body: String?

    var isSuccessful: Bool { (200...299).contains(statusCode) }
}

enum HTTPClientError: Error {
    /// The string could not be turned into an http(s) URL.
    case malformedURL(String)
    /// DNS, TLS, timeout, no connectivity.
    case transport(String)
}

/// Seam between the SDK and the network, so the config path is testable without one.
protocol HTTPClient: Sendable {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed client.
///
/// An ephemeral session: nothing cached, no cookies — the config call must always reach the
/// middleware, and a cached 200 would hide a revoked app. Redirects are refused, matching the
/// Android client, so a misconfigured host fails loudly rather than following a 301 somewhere
/// that strips the signature headers.
final class URLSessionHTTPClient: NSObject, HTTPClient, @unchecked Sendable {

    private let session: URLSession

    init(connectTimeout: TimeInterval, readTimeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        // URLSession has no separate connect timeout: the request timeout is the idle interval,
        // the resource timeout bounds the whole exchange.
        configuration.timeoutIntervalForRequest = connectTimeout
        configuration.timeoutIntervalForResource = connectTimeout + readTimeout
        let delegate = RedirectRefuser()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else {
            throw HTTPClientError.malformedURL(request.url)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.uppercased()
        urlRequest.httpBody = request.body
        request.headers.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }

        do {
            let (data, response) = try await data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return HTTPResponse(statusCode: status, body: String(data: data, encoding: .utf8))
        } catch {
            throw HTTPClientError.transport(error.localizedDescription)
        }
    }

    /// `URLSession.data(for:)` is iOS 15+; this bridges the completion API for iOS 13.
    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
