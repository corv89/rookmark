import Foundation

/// Canonicalizes URLs so that the same resource maps to the same string
/// (and therefore the same `BookmarkID`). Shared by the parser and `dedup`.
public enum URLNormalizer {

    /// Query parameters that never identify a resource — purely tracking.
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_reader", "utm_name", "utm_social", "utm_brand",
        "fbclid", "gclid", "dclid", "gclsrc", "msclkid", "mc_cid", "mc_eid",
        "igshid", "yclid", "_hsenc", "_hsmi", "vero_id", "wickedid",
        "ref", "ref_src", "ref_url", "spm", "scm",
    ]

    public struct DedupGroup: Sendable {
        public enum Tier: Sendable { case exact, fuzzy }
        public var tier: Tier
        public var bookmarks: [Bookmark]
    }

    public static func findDuplicates(_ bookmarks: [Bookmark]) -> [DedupGroup] {
        var groups: [DedupGroup] = []

        var byURL: [String: [Bookmark]] = [:]
        for b in bookmarks {
            let key = normalize(b.url)
            byURL[key, default: []].append(b)
        }
        for (_, bms) in byURL where bms.count > 1 {
            groups.append(DedupGroup(tier: .exact, bookmarks: bms))
        }

        var byDomainTitle: [String: [Bookmark]] = [:]
        let exactIDs = Set(groups.flatMap { $0.bookmarks.map(\.id) })
        for b in bookmarks where !exactIDs.contains(b.id) {
            let key = "\(b.domain)|\(b.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            byDomainTitle[key, default: []].append(b)
        }
        for (_, bms) in byDomainTitle where bms.count > 1 {
            groups.append(DedupGroup(tier: .fuzzy, bookmarks: bms))
        }

        return groups
    }

    public static func normalize(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw) else {
            return raw.lowercased()
        }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        if let host = comps.host, host.hasPrefix("www.") {
            comps.host = String(host.dropFirst(4))
        }
        // Drop default ports.
        if (comps.scheme == "http" && comps.port == 80) ||
           (comps.scheme == "https" && comps.port == 443) {
            comps.port = nil
        }
        // Filter tracking params; keep meaningful ones, sorted for stability.
        if let items = comps.queryItems {
            let kept = items
                .filter { !trackingParams.contains($0.name.lowercased()) }
                .sorted { $0.name < $1.name }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        comps.fragment = nil
        // Trailing slash on a non-root path is insignificant.
        if comps.path.count > 1, comps.path.hasSuffix("/") {
            comps.path = String(comps.path.dropLast())
        }
        return comps.string ?? raw.lowercased()
    }
}
