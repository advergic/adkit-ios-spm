import Foundation

/// One thing worth reporting, with the facts that describe it.
struct AnalyticsEvent {
    let name: String
    var attributes: Attributes = [:]
    var timestampMs: Int64 = Clock.system.nowEpochMillis
}

/// Serializes a batch of events into the JSON the events endpoint accepts.
///
/// Plain JSON rather than OTLP: this endpoint is ours, and wrapping a price in
/// `{"key":…,"value":{"doubleValue":…}}` would make it tedious to query. Dotted keys are expanded
/// into nested objects, so `device.screen.width_px` arrives as `{"device":{"screen":{…}}}`.
enum EventsPayload {

    static func encode(
        _ events: [AnalyticsEvent],
        context: Attributes,
        sentAtMs: Int64 = Clock.system.nowEpochMillis
    ) throws -> Data {
        var root = nest(context)
        root["sentAt"] = iso8601(sentAtMs)
        root["events"] = events.map { event -> [String: Any] in
            var json = nest(event.attributes)
            json["name"] = event.name
            json["occurredAt"] = iso8601(event.timestampMs)
            return json
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Expands dotted keys into nested objects. A key whose prefix is already a leaf is kept flat
    /// rather than overwriting it: a slightly odd key is easier to notice than a missing one.
    /// Keys are processed in sorted order so a collision always resolves the same way.
    static func nest(_ attributes: Attributes) -> [String: Any] {
        var root: [String: Any] = [:]
        for key in attributes.keys.sorted() {
            let value = encodeValue(attributes[key]!)
            let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if !insert(value, at: parts[...], into: &root) {
                root[key] = value
            }
        }
        return root
    }

    private static func insert(_ value: Any, at path: ArraySlice<String>, into node: inout [String: Any]) -> Bool {
        guard let head = path.first else { return false }
        if path.count == 1 {
            node[head] = value
            return true
        }
        var child: [String: Any]
        switch node[head] {
        case nil: child = [:]
        case let existing as [String: Any]: child = existing
        default: return false
        }
        guard insert(value, at: path.dropFirst(), into: &child) else { return false }
        node[head] = child
        return true
    }

    private static func encodeValue(_ value: AttributeValue) -> Any {
        switch value {
        case .string(let v): return v
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v.isFinite ? v : 0
        case .array(let items): return items.map(encodeValue)
        case .map(let entries): return entries.mapValues(encodeValue)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()
    private static let formatterLock = NSLock()

    /// UTC, millisecond precision.
    static func iso8601(_ millis: Int64) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        return formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}
