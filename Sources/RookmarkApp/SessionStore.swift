import Foundation
import RookmarkKit

/// Persists the review session so quitting never loses a run.
///
/// Deliberately a small JSON snapshot rather than the GRDB `Store`: what needs
/// to survive here is the *proposal under review* — which folder each bookmark
/// would move to, plus the include/judgement state the user has set — and none
/// of that exists in the store's schema, which models CLI runs and undo.
enum SessionStore {

    struct Snapshot: Codable {
        var savedAt: Date
        /// Ids present in the browser profile when this run was made. Comparing
        /// against the live profile is what tells us the run has gone stale.
        var sourceIDs: [String]
        var rows: [StoredRow]
        var newFolders: [String]
        var completed: Bool
    }

    struct StoredRow: Codable {
        var id: String
        var title: String
        var url: String
        var folder: String
        var confidence: Int
        var modelChoice: String?
        var included: Bool
        var accepted: Bool?
    }

    /// How the saved run relates to what is in the browser right now.
    struct Staleness: Equatable {
        var savedAt: Date
        /// Bookmarks the run never reached, because it was stopped or is unfinished.
        var unclassified: Int
        /// Bookmarks added to the browser since the run.
        var added: Int
        /// Bookmarks the run covers that are no longer in the browser.
        var removed: Int

        var isIncomplete: Bool { unclassified > 0 }
        var hasDrifted: Bool { added > 0 || removed > 0 }
        var isStale: Bool { isIncomplete || hasDrifted }
    }

    private static var url: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Rookmark", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session.json", directoryHint: .notDirectory)
    }

    static func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        // Losing a snapshot is never worth interrupting a run over.
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Compares a saved run against the profile as it stands now.
    static func staleness(of snapshot: Snapshot, against live: [Bookmark]) -> Staleness {
        let liveIDs = Set(live.map(\.id))
        let sourceIDs = Set(snapshot.sourceIDs)
        let classified = Set(snapshot.rows.map(\.id))

        return Staleness(
            savedAt: snapshot.savedAt,
            // Only count items still in the browser: something classified and
            // then deleted is not work left to do.
            unclassified: liveIDs.intersection(sourceIDs).subtracting(classified).count,
            added: liveIDs.subtracting(sourceIDs).count,
            removed: sourceIDs.subtracting(liveIDs).count
        )
    }
}
