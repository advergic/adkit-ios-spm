import Foundation

/// Lenient readers over `JSONSerialization` output, matching `org.json`'s `opt*` semantics the
/// Android parser relies on: a missing or mistyped value degrades to a default, never a throw.
extension Dictionary where Key == String, Value == Any {

    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    func array(_ key: String) -> [Any]? { self[key] as? [Any] }

    /// `optString`: strings as-is, numbers and booleans stringified, anything else empty.
    func string(_ key: String) -> String {
        switch self[key] {
        case let value as String: return value
        case let value as NSNumber: return value.jsonString
        default: return ""
        }
    }

    func isNull(_ key: String) -> Bool { self[key] == nil || self[key] is NSNull }

    func int(_ key: String, default fallback: Int = 0) -> Int {
        switch self[key] {
        case let value as NSNumber where !value.isBool: return value.intValue
        case let value as String: return Int(value) ?? fallback
        default: return fallback
        }
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let value as NSNumber where !value.isBool: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        switch self[key] {
        case let value as NSNumber: return value.boolValue
        case let value as String where value.lowercased() == "true": return true
        case let value as String where value.lowercased() == "false": return false
        default: return fallback
        }
    }

    /// A free-form object as non-blank strings — credentials blocks.
    func stringMap(_ key: String) -> [String: String] {
        guard let object = object(key) else { return [:] }
        var result: [String: String] = [:]
        for name in object.keys {
            let value = object.string(name)
            if !value.trimmingCharacters(in: .whitespaces).isEmpty { result[name] = value }
        }
        return result
    }
}

extension NSNumber {
    /// `JSONSerialization` decodes `true`/`false` as NSNumber too; this tells them apart.
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }

    var jsonString: String {
        if isBool { return boolValue ? "true" : "false" }
        return stringValue
    }
}
