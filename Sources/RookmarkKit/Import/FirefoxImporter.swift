import Foundation
import GRDB

/// Reads bookmarks directly out of a Firefox profile's `places.sqlite`.
///
/// Three things about that database shape this importer:
///
/// - `moz_bookmarks` is a flat parent-linked table like Orion's plist, so the
///   folder path is reconstructed by walking `parent`.
/// - The subtree under the `tags________` root looks exactly like folders full
///   of bookmarks but is Firefox's tag index: the same page appears once per tag
///   it carries. It is skipped entirely, folders and all.
/// - `place:` URLs are saved searches and smart folders — a query, not a page.
///
/// The database is opened read-only. Firefox runs it in WAL mode, which lets a
/// reader in while the browser has it open, so nothing is copied aside.
public enum FirefoxImporter {

    public enum Error: Swift.Error, CustomStringConvertible {
        case placesNotFound
        /// The profile is there and macOS refused the read — the same Full
        /// Disk Access wall Safari's bookmarks sit behind (see
        /// `SafariImporter`). Actionable, unlike `placesNotFound`.
        case permissionDenied
        case unreadable(String)

        public var description: String {
            switch self {
            case .placesNotFound:
                return "No Firefox profile found. Is Firefox installed for this user?"
            case .permissionDenied:
                return "Firefox's bookmarks are behind Full Disk Access. Grant it in System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again."
            case .unreadable(let detail):
                return "Firefox's places.sqlite could not be read: \(detail)"
            }
        }
    }

    /// What the source database looked like, so callers can report on it.
    public struct Summary: Sendable, Equatable {
        public var bookmarkCount: Int
        public var folderCount: Int
        /// Bookmarks dropped because an earlier entry had the same normalized URL.
        public var duplicatesSkipped: Int

        public init(bookmarkCount: Int = 0, folderCount: Int = 0, duplicatesSkipped: Int = 0) {
            self.bookmarkCount = bookmarkCount
            self.folderCount = folderCount
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

    /// One `moz_bookmarks` row with its page URL joined in.
    struct Entry {
        var id: Int64
        var type: Int
        var parent: Int64?
        var title: String?
        /// Microseconds since the Unix epoch (note: *not* milliseconds).
        var dateAdded: Double?
        var guid: String?
        var url: String?
    }

    static let bookmarkType = 1
    static let folderType = 2
    /// Type 3 is a separator, which has neither a URL nor a name.

    static let tagsRootGUID = "tags________"

    // MARK: - Locating the profile

    /// Nil covers "not installed" and "not allowed" alike — use
    /// `isBlockedByFullDiskAccess(fileManager:)` to tell those apart, for the
    /// same reason `ChromiumImporter.isBlockedByFullDiskAccess(for:fileManager:)`
    /// exists: Firefox's profile data sits behind the same Full Disk Access
    /// wall Safari's bookmarks do, which macOS never raises on an app's behalf.
    public static func defaultPlacesURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return placesURL(
            inRoot: support.appending(path: "Firefox", directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    /// Whether Firefox's profile data is on this Mac but Rookmark isn't
    /// allowed to read it. `profiles.ini` sits directly under the Firefox
    /// support folder — the depth at which a TCC denial reports honestly, the
    /// same depth `ChromiumImporter` probes `Local State` at — while the
    /// profile directory and `places.sqlite` inside it, one and two levels
    /// deeper, report as merely missing under the identical denial.
    public static func isBlockedByFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        return isBlockedByFullDiskAccess(
            inRoot: support.appending(path: "Firefox", directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    static func isBlockedByFullDiskAccess(inRoot root: URL, fileManager: FileManager = .default) -> Bool {
        let marker = root.appending(path: "profiles.ini", directoryHint: .notDirectory)
        let path = marker.path(percentEncoded: false)
        return fileManager.fileExists(atPath: path) && !fileManager.isReadableFile(atPath: path)
    }

    static func placesURL(inRoot root: URL, fileManager: FileManager = .default) -> URL? {
        for profile in profileCandidates(inRoot: root, fileManager: fileManager) {
            let places = profile.appending(path: "places.sqlite", directoryHint: .notDirectory)
            if fileManager.isReadableFile(atPath: places.path(percentEncoded: false)) {
                return places
            }
        }
        return nil
    }

    /// Profile directories, best guess first.
    ///
    /// Which profile is the default is recorded in two different places and
    /// which one is authoritative depends on the version: since Firefox 67 a
    /// per-installation `installs.ini` names it *by path*, so two channels on
    /// one Mac cannot fight over a single profile; older and hand-made setups
    /// only mark `Default=1` on a `[ProfileN]` section in `profiles.ini`. With
    /// neither present the most recently modified profile directory is the
    /// best available answer.
    static func profileCandidates(inRoot root: URL, fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        for section in parseINI(at: root.appending(path: "installs.ini", directoryHint: .notDirectory)) {
            guard let path = section.values["Default"], !path.isEmpty else { continue }
            candidates.append(resolve(path, isRelative: !path.hasPrefix("/"), against: root))
        }

        for section in parseINI(at: root.appending(path: "profiles.ini", directoryHint: .notDirectory)) {
            guard section.values["Default"] == "1", let path = section.values["Path"] else { continue }
            candidates.append(resolve(path, isRelative: section.values["IsRelative"] != "0", against: root))
        }

        let profiles = root.appending(path: "Profiles", directoryHint: .isDirectory)
        let directories = (try? fileManager.contentsOfDirectory(
            at: profiles,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        candidates += directories.sorted { modificationDate(of: $0) > modificationDate(of: $1) }

        return candidates
    }

    private static func resolve(_ path: String, isRelative: Bool, against root: URL) -> URL {
        isRelative ? root.appending(path: path, directoryHint: .isDirectory) : URL(filePath: path)
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    struct INISection {
        var name: String
        var values: [String: String] = [:]
    }

    static func parseINI(at url: URL) -> [INISection] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var sections: [INISection] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                sections.append(INISection(name: String(line.dropFirst().dropLast())))
            } else if !line.hasPrefix(";"), !line.hasPrefix("#"), !sections.isEmpty,
                      let separator = line.firstIndex(of: "=") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        return sections
    }

    // MARK: - Importing

    public static func importBookmarks(fileManager: FileManager = .default) throws -> Result {
        guard let url = defaultPlacesURL(fileManager: fileManager) else {
            throw isBlockedByFullDiskAccess(fileManager: fileManager) ? Error.permissionDenied : Error.placesNotFound
        }
        return try importBookmarks(at: url)
    }

    public static func importBookmarks(at url: URL, fileManager: FileManager = .default) throws -> Result {
        let path = url.path(percentEncoded: false)
        // Access can be revoked between the card offering Firefox and the
        // click that loads it, so this is a live path, not a fallback.
        if fileManager.fileExists(atPath: path), !fileManager.isReadableFile(atPath: path) {
            throw Error.permissionDenied
        }

        var configuration = Configuration()
        // Never a write: this database belongs to Firefox, and a running
        // Firefox is the normal case.
        configuration.readonly = true

        do {
            let queue = try DatabaseQueue(
                path: url.path(percentEncoded: false), configuration: configuration
            )
            // Ordered by id so the import — and the folder list it produces —
            // is reproducible.
            let rows = try queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT b.id AS id, b.type AS type, b.parent AS parent, b.title AS title,
                           b.dateAdded AS dateAdded, b.guid AS guid, p.url AS url
                    FROM moz_bookmarks b
                    LEFT JOIN moz_places p ON p.id = b.fk
                    ORDER BY b.id
                    """)
            }
            return importBookmarks(entries: rows.map {
                Entry(
                    id: $0["id"], type: $0["type"] ?? 0, parent: $0["parent"],
                    title: $0["title"], dateAdded: $0["dateAdded"],
                    guid: $0["guid"], url: $0["url"]
                )
            })
        } catch let error as DatabaseError {
            throw Error.unreadable(String(describing: error))
        }
    }

    static func importBookmarks(entries: [Entry]) -> Result {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tagsRootID = entries.first { $0.guid == tagsRootGUID }?.id

        var bookmarks: [Bookmark] = []
        var seenIDs = Set<String>()
        var existingFolders: [String] = []
        var existingFolderSet = Set<String>()
        var summary = Summary()

        for entry in entries where entry.type == folderType {
            guard entry.id != tagsRootID,
                  folderPath(for: entry, in: byID, tagsRootID: tagsRootID) != nil else { continue }
            summary.folderCount += 1
            if let title = entry.title, !title.isEmpty, existingFolderSet.insert(title).inserted {
                existingFolders.append(title)
            }
        }

        for entry in entries {
            guard entry.type == bookmarkType, let rawURL = entry.url, isWebURL(rawURL) else { continue }
            guard let path = folderPath(for: entry, in: byID, tagsRootID: tagsRootID) else { continue }

            let id = BookmarkID.make(forNormalizedURL: URLNormalizer.normalize(rawURL))
            guard seenIDs.insert(id).inserted else {
                summary.duplicatesSkipped += 1
                continue
            }

            bookmarks.append(
                Bookmark(
                    id: id,
                    title: (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    url: rawURL,
                    originalFolderPath: path,
                    addedAt: entry.dateAdded.map { Date(timeIntervalSince1970: $0 / 1_000_000) }
                )
            )
        }

        summary.bookmarkCount = bookmarks.count
        return Result(
            parse: ParseResult(bookmarks: bookmarks, existingFolders: existingFolders),
            summary: summary
        )
    }

    /// Walks `parent` links to build the folder path, outermost first. Nil means
    /// the entry lives under the tags root, and is therefore a tag rather than
    /// anything the user filed. The places roots carry empty titles, which drop
    /// out of the path the same way Orion's invisible root does.
    static func folderPath(
        for entry: Entry, in byID: [Int64: Entry], tagsRootID: Int64?
    ) -> [String]? {
        var path: [String] = []
        var visited = Set<Int64>()
        var current = entry.parent

        while let parentID = current, visited.insert(parentID).inserted {
            if parentID == tagsRootID { return nil }
            guard let parent = byID[parentID], parent.type == folderType else { break }
            if let title = parent.title, !title.isEmpty { path.append(title) }
            current = parent.parent
        }

        return path.reversed()
    }

    /// Excludes `place:` saved searches along with `javascript:` bookmarklets
    /// and `about:` pages — none of them is a page the pipeline can classify.
    static func isWebURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}
