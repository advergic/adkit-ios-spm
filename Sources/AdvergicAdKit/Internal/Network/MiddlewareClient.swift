import Foundation

/// Talks to the Advergic middleware.
///
/// `GET {host}/config/mediation/config` with no body and no query params — the signed headers
/// carry everything the server needs.
struct MiddlewareClient {

    let baseURL: String
    let httpClient: HTTPClient
    var signer = RequestSigner()

    func fetchConfig(apiKey: String, bundleId: String) async -> Result<AdvergicRemoteConfig, AdvergicError> {
        let signed = signer.sign(apiKey: apiKey, bundleId: bundleId)
        let url = baseURL.trimmingTrailing("/") + Constants.configPath
        let request = HTTPRequest(method: "GET", url: url, headers: signed.asDictionary, body: nil)

        AdvergicLog.d("GET \(url) (bundle-id=\(bundleId), ts=\(signed.timestamp))")

        let response: HTTPResponse
        do {
            response = try await httpClient.execute(request)
        } catch HTTPClientError.malformedURL(let bad) {
            return .failure(.invalidConfiguration("Invalid baseURL '\(baseURL)': \(bad)"))
        } catch HTTPClientError.transport(let reason) {
            return .failure(.network(reason))
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        guard response.isSuccessful else {
            let error = AdvergicError.http(statusCode: response.statusCode, body: response.body)
            AdvergicLog.w("Config request rejected: \(error.message)")
            return .failure(error)
        }

        let body = response.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.isEmpty {
            AdvergicLog.e("Config response body was empty")
            return .failure(.malformedResponse("Config response body was empty"))
        }

        guard let config = AdvergicRemoteConfig.parse(body) else {
            AdvergicLog.e("Config response was not a JSON object")
            return .failure(.malformedResponse("Config response was not a JSON object"))
        }
        return .success(config)
    }
}

extension String {
    func trimmingTrailing(_ character: Character) -> String {
        var result = self
        while result.last == character { result.removeLast() }
        return result
    }
}
