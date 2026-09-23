import Foundation

/// Every way initialization can fail.
public enum AdvergicError: Error, CustomStringConvertible, LocalizedError, Sendable {

    /// The API key was empty or obviously malformed — nothing was sent.
    case invalidApiKey(String)

    /// `AdvergicConfig.baseURL` could not be turned into a request URL.
    case invalidConfiguration(String)

    /// DNS, TLS, timeout, airplane mode — the request never got an answer.
    case network(String)

    /// The middleware answered, but not with a 2xx.
    case http(statusCode: Int, body: String?)

    /// A 2xx response whose body was not usable JSON.
    case malformedResponse(String)

    public var message: String {
        switch self {
        case .invalidApiKey(let message),
             .invalidConfiguration(let message),
             .malformedResponse(let message):
            return message
        case .network(let cause):
            return "Could not reach the Advergic middleware: \(cause)"
        case .http(let statusCode, _):
            return "Config request failed with HTTP \(statusCode) (\(Self.explain(statusCode)))"
        }
    }

    /// For `.http`: true where retrying the same request can plausibly succeed.
    public var isRetryable: Bool {
        guard case .http(let status, _) = self else { return false }
        return status == 408 || status == 429 || status >= 500
    }

    /// 401/403 mean the credentials or the registration are wrong, not that the network blipped.
    var isRejection: Bool {
        guard case .http(let status, _) = self else { return false }
        return status == 401 || status == 403
    }

    public var errorDescription: String? { message }

    public var description: String {
        let name: String
        switch self {
        case .invalidApiKey: name = "InvalidApiKey"
        case .invalidConfiguration: name = "InvalidConfiguration"
        case .network: name = "Network"
        case .http: name = "Http"
        case .malformedResponse: name = "MalformedResponse"
        }
        return "\(name)(\(message))"
    }

    private static func explain(_ statusCode: Int) -> String {
        switch statusCode {
        case 400: return "malformed request"
        case 401: return "signature rejected — check the API key, or a skewed device clock"
        case 403: return "bundle id not authorised for this API key"
        case 404: return "endpoint not found — check the environment host"
        case 408, 504: return "upstream timeout"
        case 429: return "rate limited"
        case 500...599: return "middleware error"
        default: return "unexpected status"
        }
    }
}
