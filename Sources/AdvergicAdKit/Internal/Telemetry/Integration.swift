import Foundation

/// Which wrapper the SDK runs under (Unity, Flutter, …), when it is not called from Swift
/// directly. Absent for native apps, which is itself the signal.
enum Integration {

    private static let state = Locked<(name: String?, version: String?)>((nil, nil))

    static func set(name: String, version: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedVersion = version?.trimmingCharacters(in: .whitespaces)
        state.set((
            trimmedName.isEmpty ? nil : trimmedName,
            (trimmedVersion?.isEmpty ?? true) ? nil : trimmedVersion
        ))
    }

    /// `sdk.wrapper` is a string on the wire and `sdk.wrapper_version` a sibling of it, not a
    /// child: analytics expands dotted keys into objects, and the events collector's schema has
    /// `sdk.wrapper` as a string — it answers 200 and drops a batch that nests it.
    static func attributes() -> Attributes {
        let current = state.get()
        var result: Attributes = [:]
        if let name = current.name { result["sdk.wrapper"] = .string(name) }
        if let version = current.version { result["sdk.wrapper_version"] = .string(version) }
        return result
    }

    static func reset() { state.set((nil, nil)) }
}
