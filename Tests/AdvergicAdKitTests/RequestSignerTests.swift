import CommonCrypto
import XCTest
@_spi(AdvergicAdapters) @testable import AdvergicAdKit

final class RequestSignerTests: XCTestCase {

    private let fixedClock = Clock { Date(timeIntervalSince1970: 1_700_000_000.789) }

    /// An implementation independent of CryptoKit, so a shared bug can't pass both.
    private func referenceHmac(key: String, message: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let keyBytes = Array(key.utf8)
        let messageBytes = Array(message.utf8)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes, keyBytes.count, messageBytes, messageBytes.count, &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func testSignatureIsHmacSha256OfTheBundleIdKeyedByTheApiKey() {
        let signed = RequestSigner(clock: fixedClock).sign(apiKey: "adv_live_secret", bundleId: "com.example.app")
        XCTAssertEqual(signed.signature, referenceHmac(key: "adv_live_secret", message: "com.example.app"))
    }

    func testKnownVector() {
        // RFC 4231 test case 2.
        XCTAssertEqual(
            RequestSigner.hmacSha256Hex(key: "Jefe", message: "what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
    }

    func testSignatureIsLowercaseHexOf32Bytes() {
        let signature = RequestSigner().sign(apiKey: "adv_live_secret", bundleId: "com.example.app").signature
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(signature.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testSignatureIsStableForTheSameKeyAndBundle() {
        let signer = RequestSigner(clock: fixedClock)
        XCTAssertEqual(signer.sign(apiKey: "k1234567", bundleId: "b").signature,
                       signer.sign(apiKey: "k1234567", bundleId: "b").signature)
    }

    func testADifferentBundleIdChangesTheSignature() {
        let signer = RequestSigner()
        XCTAssertNotEqual(signer.sign(apiKey: "k1234567", bundleId: "a").signature,
                          signer.sign(apiKey: "k1234567", bundleId: "b").signature)
    }

    func testADifferentApiKeyChangesTheSignature() {
        let signer = RequestSigner()
        XCTAssertNotEqual(signer.sign(apiKey: "k1234567", bundleId: "a").signature,
                          signer.sign(apiKey: "k7654321", bundleId: "a").signature)
    }

    func testTimestampIsUnixSecondsNotMillis() {
        XCTAssertEqual(RequestSigner(clock: fixedClock).sign(apiKey: "k1234567", bundleId: "b").timestamp, 1_700_000_000)
    }

    /// The Android contract's three headers, plus `platform` — see PLAN.md Q1.
    func testSendsTheContractHeadersPlusPlatform() {
        let headers = RequestSigner(clock: fixedClock).sign(apiKey: "k1234567", bundleId: "com.example.app").asDictionary
        XCTAssertEqual(Set(headers.keys), ["timestamp", "signature", "bundle-id", "platform"])
        XCTAssertEqual(headers["bundle-id"], "com.example.app")
        XCTAssertEqual(headers["timestamp"], "1700000000")
        XCTAssertEqual(headers["platform"], "ios")
    }
}
