import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class MiddlewareClientTests: XCTestCase {

    private func client(_ http: FakeHTTPClient, baseURL: String = "https://example.test") -> MiddlewareClient {
        MiddlewareClient(baseURL: baseURL, httpClient: http, signer: RequestSigner(clock: Clock { Date(timeIntervalSince1970: 1) }))
    }

    private func fetch(_ http: FakeHTTPClient, baseURL: String = "https://example.test") async -> Result<AdvergicRemoteConfig, AdvergicError> {
        await client(http, baseURL: baseURL).fetchConfig(apiKey: "adv_test_key", bundleId: "com.example.app")
    }

    func testIssuesABodylessGetWithTheSignedHeaders() async {
        let http = FakeHTTPClient()
        _ = await fetch(http)
        let request = try! XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.headers["bundle-id"], "com.example.app")
        XCTAssertEqual(request.headers["signature"],
                       RequestSigner.hmacSha256Hex(key: "adv_test_key", message: "com.example.app"))
    }

    func testNoQueryParamsAreAppended() async {
        let http = FakeHTTPClient()
        _ = await fetch(http)
        XCTAssertEqual(http.requests.first?.url, "https://example.test/config/mediation/config")
    }

    func testTrailingSlashInBaseUrlDoesNotDoubleUp() async {
        let http = FakeHTTPClient()
        _ = await fetch(http, baseURL: "https://example.test//")
        XCTAssertEqual(http.requests.first?.url, "https://example.test/config/mediation/config")
    }

    func testKeepsTheRawBodyAndExposesItParsed() async throws {
        let body = #"{"mediation":{"version":3}}"#
        let config = try await fetch(FakeHTTPClient(body: body)).get()
        XCTAssertEqual(config.raw, body)
        XCTAssertEqual((config.json["mediation"] as? [String: Any])?["version"] as? Int, 3)
        XCTAssertEqual(config.keys, ["mediation"])
    }

    func testAcceptsAConfigDocumentWithUnknownFields() async throws {
        let config = try await fetch(FakeHTTPClient(body: #"{"somethingNew":[1,2],"x":null}"#)).get()
        XCTAssertEqual(config.keys, ["somethingNew", "x"])
    }

    func testMaps400ToANonRetryableHttpErrorCarryingTheBody() async {
        guard case .failure(let error) = await fetch(FakeHTTPClient(status: 400, body: "bad")) else { return XCTFail() }
        guard case .http(400, "bad") = error else { return XCTFail("\(error)") }
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(error.message.contains("malformed request"))
    }

    func testMaps401ToAnHttpErrorMentioningTheSignature() async {
        guard case .failure(let error) = await fetch(FakeHTTPClient(status: 401, body: nil)) else { return XCTFail() }
        XCTAssertTrue(error.message.contains("signature"))
        XCTAssertTrue(error.isRejection)
    }

    func testMaps403ToAnHttpErrorMentioningTheBundleId() async {
        guard case .failure(let error) = await fetch(FakeHTTPClient(status: 403, body: nil)) else { return XCTFail() }
        XCTAssertTrue(error.message.contains("bundle id"))
        XCTAssertTrue(error.isRejection)
    }

    func test429And5xxAreRetryable() {
        XCTAssertTrue(AdvergicError.http(statusCode: 429, body: nil).isRetryable)
        XCTAssertTrue(AdvergicError.http(statusCode: 408, body: nil).isRetryable)
        XCTAssertTrue(AdvergicError.http(statusCode: 502, body: nil).isRetryable)
        XCTAssertFalse(AdvergicError.http(statusCode: 404, body: nil).isRetryable)
    }

    func testMapsTransportFailuresToANetworkError() async {
        let http = FakeHTTPClient()
        http.error = HTTPClientError.transport("offline")
        guard case .failure(.network(let reason)) = await fetch(http) else { return XCTFail() }
        XCTAssertEqual(reason, "offline")
    }

    func testMapsABadUrlToAnInvalidConfiguration() async {
        let http = FakeHTTPClient()
        http.error = HTTPClientError.malformedURL("nope")
        guard case .failure(.invalidConfiguration) = await fetch(http) else { return XCTFail() }
    }

    func testTheRealClientRejectsANonHttpUrl() async {
        let real = URLSessionHTTPClient(connectTimeout: 1, readTimeout: 1)
        let result = await MiddlewareClient(baseURL: "not a url", httpClient: real)
            .fetchConfig(apiKey: "adv_test_key", bundleId: "b")
        guard case .failure(.invalidConfiguration) = result else { return XCTFail("\(result)") }
    }

    func testMapsAnEmptySuccessBodyToAMalformedResponse() async {
        guard case .failure(.malformedResponse) = await fetch(FakeHTTPClient(body: "  \n")) else { return XCTFail() }
    }

    func testMapsANonJsonSuccessBodyToAMalformedResponse() async {
        guard case .failure(.malformedResponse) = await fetch(FakeHTTPClient(body: "<html>")) else { return XCTFail() }
        guard case .failure(.malformedResponse) = await fetch(FakeHTTPClient(body: "[1,2]")) else { return XCTFail() }
    }
}
