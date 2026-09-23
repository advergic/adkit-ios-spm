import Foundation

/// An MMP the publisher connected, from `connectedMmps` (or the legacy `connectedMmp`).
///
/// Attribution is separate from mediation: it does not decide which ad shows, it records what
/// the shown ad earned so the MMP can attribute revenue to whichever campaign acquired the user.
struct RemoteMmp: Equatable, CustomStringConvertible {

    /// Catalog id, e.g. `appsflyer`. Lower-cased so a dashboard's casing cannot matter.
    let id: String
    let credentials: [String: String]
    /// Formats whose revenue should be forwarded, as dashboard slugs. Empty means every format —
    /// a publisher who lists only `rewarded` must not have the rest sent anyway.
    let formats: Set<String>

    func credential(_ key: String) -> String? {
        guard let value = credentials[key], !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }

    func reports(format: String) -> Bool {
        formats.isEmpty || formats.contains(format.lowercased())
    }

    var formatsDescription: String {
        formats.isEmpty ? "every ad format" : formats.sorted().joined(separator: ", ")
    }

    var description: String {
        "\(id)(credentials=\(credentials.keys.sorted()), formats=\(formats.isEmpty ? ["all"] : formats.sorted()))"
    }

    /// Every MMP the publisher connected, in config order.
    ///
    /// `connectedMmps` (array) wins over `connectedMmp` (single object). Duplicates collapse to
    /// the first entry — two reporters for one MMP would double that publisher's revenue. Never
    /// throws: losing attribution is a data gap, losing the ad stack is lost revenue.
    static func parseAll(_ json: [String: Any]) -> [RemoteMmp] {
        let blocks: [[String: Any]]
        if let array = json.array("connectedMmps") {
            blocks = array.compactMap { $0 as? [String: Any] }
        } else if let single = json.object("connectedMmp") {
            blocks = [single]
        } else {
            blocks = []
        }

        var seen = Set<String>()
        return blocks
            .compactMap(parseBlock)
            .filter { seen.insert($0.id).inserted }
            .map { mmp in
                AdvergicLog.d("MMP connected: \(mmp)")
                return mmp
            }
    }

    private static func parseBlock(_ block: [String: Any]) -> RemoteMmp? {
        let id = block.string("mmpId").trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return nil }

        let formats = (block.array("formats") ?? [])
            .compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.lowercased() }

        return RemoteMmp(id: id, credentials: block.stringMap("credentials"), formats: Set(formats))
    }
}
