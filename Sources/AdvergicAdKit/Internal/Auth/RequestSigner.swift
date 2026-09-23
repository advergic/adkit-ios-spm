import CryptoKit
import Foundation

/// The headers the middleware authenticates a config request with.
struct SignedHeaders: Equatable {
    let bundleId: String
    let timestamp: Int64
    let signature: String

    var asDictionary: [String: String] {
        [
            Constants.headerTimestamp: String(timestamp),
            Constants.headerSignature: signature,
            Constants.headerBundleId: bundleId,
            Constants.headerPlatform: Constants.platformValue,
        ]
    }
}

/// Signs middleware requests: `HMAC-SHA256(key: apiKey, message: bundleId)`, lower-case hex.
///
/// The API key is the HMAC secret and never leaves the device; the bundle id is read from the
/// running app, which is what makes it usable as an identity the publisher cannot spoof.
///
/// The timestamp travels alongside for the server's replay window but is deliberately *not* part
/// of the HMAC input, matching the middleware contract. A device with a badly skewed clock will
/// therefore see 4xx even though the signature is correct.
struct RequestSigner {

    var clock: Clock = .system

    func sign(apiKey: String, bundleId: String) -> SignedHeaders {
        SignedHeaders(
            bundleId: bundleId,
            timestamp: clock.nowEpochSeconds,
            signature: Self.hmacSha256Hex(key: apiKey, message: bundleId)
        )
    }

    static func hmacSha256Hex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return Hex.encode(mac)
    }
}
