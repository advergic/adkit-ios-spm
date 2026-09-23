import Foundation

enum Severity: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// One log line on its way to the collector. `timestampMs` is taken at the call site: batching
/// means send time can be seconds later, and queue delay must not look like a late event.
struct OtlpLogRecord {
    let event: String
    let severity: Severity
    let body: String
    var adUnitId: String?
    var adUnitType: String?
    var errorMessage: String?
    var attributes: Attributes = [:]
    var timestampMs: Int64 = Clock.system.nowEpochMillis
}

/// Serializes records into OTLP/HTTP JSON, the shape the shared collector accepts from every
/// Advergic SDK.
///
/// Built with `JSONSerialization`, never by concatenation: ad unit ids and network error strings
/// end up inside JSON string literals, and the collector rejects a malformed body with 400 —
/// one bad escape would silently drop the whole batch.
enum OtlpPayload {

    static let scopeName = "AdvergicSDK"

    static func encode(
        _ records: [OtlpLogRecord],
        serviceName: String,
        resourceAttributes: Attributes = [:],
        serviceVersion: String = Constants.sdkVersion,
        environment: String = Constants.isDevMode ? "dev" : "prod"
    ) throws -> Data {
        var resource: [[String: Any]] = [
            attribute("service.name", .string(serviceName)),
            attribute("service.version", .string(serviceVersion)),
            attribute("deployment.environment", .string(environment)),
        ]
        // Device and app facts describe the emitter, not any one event.
        resource += resourceAttributes.keys.sorted().map { attribute($0, resourceAttributes[$0]!) }

        let root: [String: Any] = [
            "resourceLogs": [[
                "resource": ["attributes": resource],
                "scopeLogs": [[
                    "scope": ["name": scopeName],
                    "logRecords": records.map(encodeRecord),
                ]],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func encodeRecord(_ record: OtlpLogRecord) -> [String: Any] {
        var attributes: [[String: Any]] = [attribute("event.name", .string(record.event))]
        if let id = record.adUnitId { attributes.append(attribute("ad.unit.id", .string(id))) }
        if let type = record.adUnitType { attributes.append(attribute("ad.unit.type", .string(type))) }
        if let error = record.errorMessage { attributes.append(attribute("error.message", .string(error))) }
        attributes += record.attributes.keys.sorted().map { attribute($0, record.attributes[$0]!) }

        return [
            // Nanoseconds, as a string: the collector rejects milliseconds outright, and the
            // number exceeds what a JSON double holds exactly.
            "timeUnixNano": String(record.timestampMs) + "000000",
            "severityText": record.severity.rawValue,
            "body": ["stringValue": record.body],
            "attributes": attributes,
        ]
    }

    private static func attribute(_ key: String, _ value: AttributeValue) -> [String: Any] {
        ["key": key, "value": encodeValue(value)]
    }

    /// OTLP's AnyValue. Integers travel as strings (int64 does not fit a JSON number exactly);
    /// doubles travel as numbers.
    private static func encodeValue(_ value: AttributeValue) -> [String: Any] {
        switch value {
        case .string(let v): return ["stringValue": v]
        case .bool(let v): return ["boolValue": v]
        case .int(let v): return ["intValue": String(v)]
        case .double(let v): return ["doubleValue": v.isFinite ? v : 0]
        case .array(let items): return ["arrayValue": ["values": items.map(encodeValue)]]
        case .map(let entries):
            return ["kvlistValue": ["values": entries.keys.sorted().map { attribute($0, entries[$0]!) }]]
        }
    }
}
