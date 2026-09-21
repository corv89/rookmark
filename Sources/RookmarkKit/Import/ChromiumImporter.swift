import Foundation

/// Reads bookmarks directly out of a Chromium-family profile — Chrome, Brave,
/// Edge and Vivaldi.
///
/// All four ship the same `Bookmarks` JSON and the same profile layout, so the
/// browser is a parameter (`Product`) rather than four near-identical importers;
/// only the Application Support subdirectory differs between them.
///
/// Two format details worth naming, both of which are easy to get wrong:
///
/// - Which profile is live is recorded in a *different* file: `Local State`,
///   under `profile.last_used`. A single-profile install often has neither the
///   key nor the file, and its directory is then literally `Default`.
/// - `date_added` counts **microseconds since 1601-01-01** — the Windows
///   FILETIME epoch Chromium inherited, not the Unix epoch.
public enum ChromiumImporter {

    /// The browsers that share this format. Raw values double as the CLI's
    /// `--browser` argument.
    public enum Product: String, Sendable, CaseIterable {
        case chrome, brave, edge, vivaldi

        public var displayName: String {
            switch self {
            case .chrome: "Chrome"
            case .brave: "Brave"
            case .edge: "Edge"
            case .vivaldi: "Vivaldi"
            }
        }

        /// Path under `~/Library/Application Support` holding `Local State` and
        /// the profile directories.
        var supportSubpath: String {
            switch self {
            case .chrome: "Google/Chrome"
            case .brave: "BraveSoftware/Brave-Browser"
            case .edge: "Microsoft Edge"
            case .vivaldi: "Vivaldi"
            }
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case bookmarksNotFound(Product)
        /// The profile is there and macOS refused the read — the same Full
        /// Disk Access wall Safari's bookmarks sit behind (see
        /// `SafariImporter`), not a lighter prompt the user could have
        /// declined. Actionable, unlike the other two.
        case permissionDenied(Product)
        case malformed(String)

        public var description: String {
            switch self {
            case .bookmarksNotFound(let product):
                return "No \(product.displayName) bookmarks found. Is \(product.displayName) installed for this user?"
            case .permissionDenied(let product):
                return "\(product.displayName)'s bookmarks are behind Full Disk Access. Grant it in System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again."
            case .malformed(let detail):
                return "The Chromium Bookmarks file is not in the expected format: \(detail)"
            }
        }
    }

    /// What the source file looked like, so callers can report on it.
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

    /// The three fixed roots. Decoded by name rather than as a dictionary
    /// because older profiles keep a `sync_transaction_version` string in
    /// `roots` alongside the folders, which no node decoder can accept.
    struct File: Decodable {
        struct Roots: Decodable {
            var bookmarkBar: Node?
            var other: Node?
            var synced: Node?

            /// Fixed order: JSON object order is not meaningful, and the import
            /// has to be reproducible.
            var ordered: [Node] { [bookmarkBar, other, synced].compactMap { $0 } }
        }

        var roots: Roots
    }

    /// One node of the tree. Unknown keys (`id`, `guid`, `date_modified`, …) are
    /// ignored by the decoder.
    struct Node: Decodable {
        var type: String?
        var name: String?
        var url: String?
        /// Microseconds since 1601-01-01, written as a decimal *string*: the
        /// value is past what a JSON number carries without losing precision.
        var dateAdded: String?
        var children: [Node]?

        var isFolder: Bool { type == "folder" }
        var isBookmark: Bool { type == "url" }
    }

    // MARK: - Locating the profile

    /// Nil covers "not installed" and "not allowed" alike — use
    /// `isBlockedByFullDiskAccess(for:fileManager:)` to tell those apart.
    /// Another app's Application Support data sits behind the same Full Disk
    /// Access wall Safari's bookmarks do (see `SafariImporter`), not a
    /// separate, lighter prompt: macOS never raises it on an app's behalf, so
    /// a refusal here is something the user can fix, not a sign the browser
    /// isn't installed.
    public static func defaultBookmarksURL(
        for product: Product, fileManager: FileManager = .default
    ) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return bookmarksURL(
            inRoot: support.appending(path: product.supportSubpath, directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    static func bookmarksURL(inRoot root: URL, fileManager: FileManager = .default) -> URL? {
        profileCandidates(inRoot: root, fileManager: fileManager)
            .first { fileManager.isReadableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// Bookmarks files to try, best guess first.
    ///
    /// `last_used` is usually right, but not always: Chromium can leave it
    /// pointing at a profile with no real bookmarks in it — most commonly
    /// `System Profile`, when the browser was last closed on its
    /// profile-picker screen rather than inside an actual profile. Trusting
    /// that single guess with nothing to fall back to then fails silently,
    /// indistinguishable from "not installed" even with a real, readable
    /// profile sitting right there — so this tries `last_used`, then the
    /// near-universal `Default`, then every other profile directory Chromium
    /// created, most-recently-touched `Bookmarks` file first. The same
    /// "ranked candidates, not one guess" shape
    /// `FirefoxImporter.profileCandidates` already uses, for the same reason.
    static func profileCandidates(inRoot root: URL, fileManager: FileManager) -> [URL] {
        var seen = Set<String>()
        var names: [String] = []
        func consider(_ name: String) {
            guard seen.insert(name).inserted else { return }
            names.append(name)
        }

        if let lastUsed = lastUsedProfile(inRoot: root) { consider(lastUsed) }
        consider("Default")

        let directories = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let rest = directories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .filter { !seen.contains($0) }
            .sorted {
                bookmarksModificationDate(profile: $0, inRoot: root)
                    > bookmarksModificationDate(profile: $1, inRoot: root)
            }
        rest.forEach(consider)

        return names.map {
            root.appending(path: $0, directoryHint: .isDirectory)
                .appending(path: "Bookmarks", directoryHint: .notDirectory)
        }
    }

    private static func bookmarksModificationDate(profile: String, inRoot root: URL) -> Date {
        let bookmarks = root
            .appending(path: profile, directoryHint: .isDirectory)
            .appending(path: "Bookmarks", directoryHint: .notDirectory)
        return (try? bookmarks.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Whether this browser's profile is on this Mac but Rookmark isn't
    /// allowed to read it.
    ///
    /// The probe is `Local State`, not the `Bookmarks` file itself: `Local
    /// State` sits one level below the browser's own support folder — the
    /// same depth Safari's `Bookmarks.plist` sits at, where a TCC denial
    /// reports honestly (`fileExists` true, `isReadableFile` false).
    /// `Bookmarks`, one level deeper still (inside the profile directory),
    /// reports as merely missing under the identical denial — measured
    /// directly against a real, permission-denied Brave profile — so probing
    /// it would misreport "not installed" for a browser that plainly is.
    public static func isBlockedByFullDiskAccess(
        for product: Product, fileManager: FileManager = .default
    ) -> Bool {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        return isBlockedByFullDiskAccess(
            inRoot: support.appending(path: product.supportSubpath, directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    static func isBlockedByFullDiskAccess(inRoot root: URL, fileManager: FileManager = .default) -> Bool {
        let localState = root.appending(path: "Local State", directoryHint: .notDirectory)
        let path = localState.path(percentEncoded: false)
        return fileManager.fileExists(atPath: path) && !fileManager.isReadableFile(atPath: path)
    }

    /// The profile directory the browser last opened. Absent on a one-profile
    /// install, where the caller's `Default` fallback is the right answer.
    static func lastUsedProfile(inRoot root: URL) -> String? {
        struct LocalState: Decodable {
            struct Profile: Decodable { var lastUsed: String? }
            var profile: Profile?
        }

        let url = root.appending(path: "Local State", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let name = (try? decoder.decode(LocalState.self, from: data))?.profile?.lastUsed,
              !name.isEmpty else { return nil }
        return name
    }

    // MARK: - Importing

    public static func importBookmarks(
        for product: Product, fileManager: FileManager = .default
    ) throws -> Result {
        guard let url = defaultBookmarksURL(for: product, fileManager: fileManager) else {
            throw isBlockedByFullDiskAccess(for: product, fileManager: fileManager)
                ? Error.permissionDenied(product)
                : Error.bookmarksNotFound(product)
        }
        return try importBookmarks(at: url, for: product)
    }

    public static func importBookmarks(
        at url: URL, for product: Product, fileManager: FileManager = .default
    ) throws -> Result {
        let path = url.path(percentEncoded: false)
        // Access can be revoked between the card offering this browser and
        // the click that loads it, so this is a live path, not a fallback.
        if fileManager.fileExists(atPath: path), !fileManager.isReadableFile(atPath: path) {
            throw Error.permissionDenied(product)
        }
        return try importBookmarks(jsonData: try Data(contentsOf: url))
    }

    public static func importBookmarks(jsonData data: Data) throws -> Result {
        let file: File
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            file = try decoder.decode(File.self, from: data)
        } catch {
            throw Error.malformed(String(describing: error))
        }

        var bookmarks: [Bookmark] = []
        var seenIDs = Set<String>()
        var existingFolders: [String] = []
        var existingFolderSet = Set<String>()
        var summary = Summary()

        func walk(_ node: Node, path: [String]) {
            if node.isFolder {
                summary.folderCount += 1
                var childPath = path
                if let name = node.name, !name.isEmpty {
                    childPath.append(name)
                    if existingFolderSet.insert(name).inserted { existingFolders.append(name) }
                }
                for child in node.children ?? [] { walk(child, path: childPath) }
                return
            }

            guard node.isBookmark, let rawURL = node.url, isWebURL(rawURL) else { return }

            let id = BookmarkID.make(forNormalizedURL: URLNormalizer.normalize(rawURL))
            guard seenIDs.insert(id).inserted else {
                summary.duplicatesSkipped += 1
                return
            }

            bookmarks.append(
                Bookmark(
                    id: id,
                    title: (node.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    url: rawURL,
                    originalFolderPath: path,
                    addedAt: node.dateAdded.flatMap(date(fromFiletimeMicroseconds:))
                )
            )
        }

        for root in file.roots.ordered { walk(root, path: []) }

        summary.bookmarkCount = bookmarks.count
        return Result(
            parse: ParseResult(bookmarks: bookmarks, existingFolders: existingFolders),
            summary: summary
        )
    }

    /// Seconds from 1601-01-01 to the Unix epoch.
    static let filetimeEpochOffset: Double = 11_644_473_600

    static func date(fromFiletimeMicroseconds raw: String) -> Date? {
        guard let micros = Double(raw), micros > 0 else { return nil }
        return Date(timeIntervalSince1970: micros / 1_000_000 - filetimeEpochOffset)
    }

    /// Chromium does not normally keep bookmarklets or internal pages in this
    /// file, but a `javascript:` or `chrome://` entry is nothing the pipeline
    /// can fetch, classify or export usefully.
    static func isWebURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}
