import Foundation

/// The config document the middleware returned for this app.
///
/// No schema is imposed: `raw` is the exact body received and `json` is that body parsed, so new
/// server-side fields are readable without an SDK release.
public final class AdvergicRemoteConfig: CustomStringConvertible, @unchecked Sendable {

    public let raw: String

    /// The parsed document. Values are `JSONSerialization` types: `String`, `NSNumber`,
    /// `[String: Any]`, `[Any]`, `NSNull`.
    public let json: [String: Any]

    init(raw: String, json: [String: Any]) {
        self.raw = raw
        self.json = json
    }

    /// Parses `raw`, or returns nil when it is not a JSON object.
    static func parse(_ raw: String) -> AdvergicRemoteConfig? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any]
        else { return nil }
        return AdvergicRemoteConfig(raw: raw, json: json)
    }

    /// Top-level keys present in the document.
    public var keys: Set<String> { Set(json.keys) }

    public var description: String {
        "AdvergicRemoteConfig(keys=\(keys.sorted()), bytes=\(raw.utf8.count))"
    }
}
