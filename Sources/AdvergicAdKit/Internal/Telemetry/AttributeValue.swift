import Foundation

/// A typed attribute value for telemetry and analytics.
///
/// Typed on purpose: a price sent as a string cannot be averaged without the collector
/// re-parsing it, and a locale-formatted decimal would corrupt silently.
enum AttributeValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case array([AttributeValue])
    case map([String: AttributeValue])
}

typealias Attributes = [String: AttributeValue]

extension AttributeValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
}

extension AttributeValue {
    static func of(_ value: String) -> AttributeValue { .string(value) }
    static func of(_ value: Int) -> AttributeValue { .int(Int64(value)) }
    static func of(_ value: Double) -> AttributeValue { .double(value) }
    static func of(_ value: Bool) -> AttributeValue { .bool(value) }
}
