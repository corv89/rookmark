import Foundation

/// Writes a Netscape Bookmark File that browsers can re-import. Bookmarks are
/// grouped into one `<H3>` folder per assigned category, with `Unsorted` last.
public struct NetscapeBookmarkWriter: Sendable {

    public init() {}

    /// - Parameter bookmarks: each should have `assignedFolder` set; any nil
    ///   assignment falls back to `Taxonomy.unsorted`.
    public func write(_ bookmarks: [Bookmark]) -> String {
        var groups: [String: [Bookmark]] = [:]
        for b in bookmarks {
            groups[b.assignedFolder ?? Taxonomy.unsorted, default: []].append(b)
        }

        // Stable order: alphabetical, Unsorted pinned last.
        let names = groups.keys.sorted { a, b in
            if a == Taxonomy.unsorted { return false }
            if b == Taxonomy.unsorted { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        for name in names {
            out += "    <DT><H3>\(Self.escape(name))</H3>\n"
            out += "    <DL><p>\n"
            for b in groups[name]!.sorted(by: { $0.title < $1.title }) {
                let date = b.addedAt.map { " ADD_DATE=\"\(Int($0.timeIntervalSince1970))\"" } ?? ""
                out += "        <DT><A HREF=\"\(Self.escape(b.url))\"\(date)>\(Self.escape(b.title))</A>\n"
            }
            out += "    </DL><p>\n"
        }
        out += "</DL><p>\n"
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
