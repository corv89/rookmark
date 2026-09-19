import Foundation

/// Reads bookmarks directly out of an Orion (Kagi) profile.
///
/// Orion stores favourites as a **flat** binary plist dictionary keyed by entry
/// id — not a nested tree. Each value is a folder or a bookmark carrying a
/// `parentId`, so the folder path has to be reconstructed by walking parent
/// links.
///
/// Two real-world irregularities this handles, both observed in a live profile:
///
/// - A partial import can bring bookmarks across while dropping the folder
///   entries they point at, leaving every `parentId` dangling. Such bookmarks
///   are imported at root rather than discarded, and counted in
///   `Summary.orphanedFolderReferences` so callers can surface the fact that the
///   source's structure was already broken.
/// - After a version migration the live file sits at `Defaults/favourites.plist`
///   while a near-empty stub remains under `Defaults/bk_<version>/`, so the
///   top-level file is preferred and the versioned one is only a fallback.
public enum OrionImporter {

    public enum Error: Swift.Error, CustomStringConvertible {
        case favouritesNotFound
        case malformed(String)

        public var description: String {
            switch self {
            case .favouritesNotFound:
                return "No Orion favourites.plist found. Is Orion installed for this user?"
            case .malformed(let detail):
                return "Orion favourites.plist is not in the expected format: \(detail)"
            }
        }
    }

    /// What the source file looked like, so callers can report on it.
    public struct Summary: Sendable, Equatable {
        public var bookmarkCount: Int
        public var folderCount: Int
        /// Bookmarks whose `parentId` resolved to a real folder entry.
        public var withResolvedFolder: Int
        /// Bookmarks whose `parentId` pointed at a folder that doesn't exist.
        public var orphanedFolderReferences: Int
        /// Distinct folder ids referenced but absent from the file.
        public var missingFolderIDs: Int
        /// Bookmarks dropped because an earlier entry had the same normalized URL.
        public var duplicatesSkipped: Int

        public init(
            bookmarkCount: Int = 0,
            folderCount: Int = 0,
            withResolvedFolder: Int = 0,
            orphanedFolderReferences: Int = 0,
            missingFolderIDs: Int = 0,
            duplicatesSkipped: Int = 0
        ) {
            self.bookmarkCount = bookmarkCount
            self.folderCount = folderCount
            self.withResolvedFolder = withResolvedFolder
            self.orphanedFolderReferences = orphanedFolderReferences
            self.missingFolderIDs = missingFolderIDs
            self.duplicatesSkipped = duplicatesSkipped
        }
    }

    public struct Result: Sendable {
        public var parse: ParseResult
        public var summary: Summary

        public init(parse: ParseResult, summary: Summary) {
            self.parse = parse
            self.summary = summary
        }
    }

    /// One entry in the favourites dictionary. Unknown keys (`index`,
    /// `lastSynced`, `unmodifiable`, …) are ignored by the decoder.
    struct Entry: Decodable {
        var id: String?
        var type: String?
        var title: String?
        var url: String?
        var parentId: String?
        /// Milliseconds since the Unix epoch (note: *not* seconds).
        var dateAdded: Double?

        var isFolder: Bool { type == "folder" }
        var isBookmark: Bool { type == "bookmark" }
    }

    // MARK: - Locating the profile

    /// The live favourites file, preferring `Defaults/favourites.plist` and
    /// falling back to the most recently modified `Defaults/bk_*/favourites.plist`.
    public static func defaultFavouritesURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let defaults = support.appending(path: "Orion/Defaults", directoryHint: .isDirectory)

        let live = defaults.appending(path: "favourites.plist", directoryHint: .notDirectory)
        if fileManager.isReadableFile(atPath: live.path(percentEncoded: false)) {
            return live
        }

        let backups = (try? fileManager.contentsOfDirectory(
            at: defaults,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return backups
            .filter { $0.lastPathComponent.hasPrefix("bk_") }
            .map { $0.appending(path: "favourites.plist", directoryHint: .notDirectory) }
            .filter { fileManager.isReadableFile(atPath: $0.path(percentEncoded: false)) }
            .max { lhs, rhs in modificationDate(of: lhs) < modificationDate(of: rhs) }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Importing

    public static func importFavourites(fileManager: FileManager = .default) throws -> Result {
        guard let url = defaultFavouritesURL(fileManager: fileManager) else {
            throw Error.favouritesNotFound
        }
        return try importFavourites(at: url)
    }

    public static func importFavourites(at url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        return try importFavourites(plistData: data)
    }

    public static func importFavourites(plistData data: Data) throws -> Result {
        let entries: [String: Entry]
        do {
            entries = try PropertyListDecoder().decode([String: Entry].self, from: data)
        } catch {
            throw Error.malformed(String(describing: error))
        }

        var bookmarks: [Bookmark] = []
        var seenIDs = Set<String>()
        var existingFolders: [String] = []
        var existingFolderSet = Set<String>()
        var summary = Summary()
        var missingFolderIDs = Set<String>()

        // Sorted by id throughout: the dictionary has no meaningful ordering, and
        // both the folder list and downstream batching should be reproducible.
        let ordered = entries.sorted { $0.key < $1.key }

        for (_, entry) in ordered where entry.isFolder {
            summary.folderCount += 1
            if let title = entry.title, !title.isEmpty, existingFolderSet.insert(title).inserted {
                existingFolders.append(title)
            }
        }

        for (_, entry) in ordered {
            guard entry.isBookmark, let rawURL = entry.url, !rawURL.isEmpty else { continue }

            let normalized = URLNormalizer.normalize(rawURL)
            let id = BookmarkID.make(forNormalizedURL: normalized)
            guard seenIDs.insert(id).inserted else {
                summary.duplicatesSkipped += 1
                continue
            }

            let (path, resolvedParent, missingID) = folderPath(for: entry, in: entries)
            if let missingID { missingFolderIDs.insert(missingID) }
            if resolvedParent {
                summary.withResolvedFolder += 1
            } else {
                summary.orphanedFolderReferences += 1
            }

            bookmarks.append(
                Bookmark(
                    id: id,
                    title: (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    url: rawURL,
                    originalFolderPath: path,
                    addedAt: entry.dateAdded.map { Date(timeIntervalSince1970: $0 / 1000) }
                )
            )
        }

        summary.bookmarkCount = bookmarks.count
        summary.missingFolderIDs = missingFolderIDs.count

        return Result(
            parse: ParseResult(bookmarks: bookmarks, existingFolders: existingFolders),
            summary: summary
        )
    }

    /// Walks `parentId` links to build the folder path, outermost first.
    ///
    /// Returns whether the immediate parent resolved, plus the id of the first
    /// referenced-but-absent folder, so the caller can distinguish "lives at the
    /// root" from "points at a folder that no longer exists".
    static func folderPath(
        for entry: Entry,
        in entries: [String: Entry]
    ) -> (path: [String], resolvedParent: Bool, missingID: String?) {
        guard let firstParent = entry.parentId, !firstParent.isEmpty else {
            return ([], true, nil)
        }

        var path: [String] = []
        var visited = Set<String>()
        var current: String? = firstParent
        var resolvedFirst = false
        var missingID: String?

        while let parentID = current, !parentID.isEmpty, visited.insert(parentID).inserted {
            guard let parent = entries[parentID], parent.isFolder else {
                if missingID == nil { missingID = parentID }
                break
            }
            if parentID == firstParent { resolvedFirst = true }
            if let title = parent.title, !title.isEmpty {
                path.append(title)
            }
            current = parent.parentId
        }

        return (path.reversed(), resolvedFirst, missingID)
    }
}
