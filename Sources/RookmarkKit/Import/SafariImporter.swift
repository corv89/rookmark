import Foundation

/// Reads bookmarks directly out of `~/Library/Safari/Bookmarks.plist`.
///
/// Two things set this importer apart from the other live ones:
///
/// - **The format is loose.** It is a nested tree like Chromium's, but the keys
///   vary by macOS version, several are optional, and a leaf often carries its
///   title twice (`Title` and `URIDictionary.title`) with only one of them
///   filled in. It is walked as `[String: Any]` rather than decoded into a
///   model, so an unrecognized node is skipped instead of failing the import —
///   the opposite trade from `OrionImporter.Entry`, whose flat dictionary has
///   one uniform shape worth pinning with `Decodable`.
/// - **The file is behind Full Disk Access**, a stricter TCC category than the
///   app-data prompt Chromium profiles trigger. macOS never raises it on an
///   app's behalf, so a refusal here is not "no profile" — it is a condition
///   the user can lift from System Settings, which is why `.permissionDenied`
///   is its own case rather than folded into `.bookmarksNotFound`.
///
/// Safari records no add date for a bookmark, so every imported `addedAt` is
/// nil; the pipeline does not depend on it.
public enum SafariImporter {

    public enum Error: Swift.Error, CustomStringConvertible {
        case bookmarksNotFound
        /// The file is there and macOS refused the read. Actionable, unlike the
        /// other two: the user grants Full Disk Access and tries again.
        case permissionDenied
        case malformed(String)

        public var description: String {
            switch self {
            case .bookmarksNotFound:
                return "No Safari bookmarks found at ~/Library/Safari/Bookmarks.plist. Is Safari set up for this user?"
            case .permissionDenied:
                return "Safari's bookmarks are behind Full Disk Access. Grant it in System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again."
            case .malformed(let detail):
                return "Safari's Bookmarks.plist is not in the expected format: \(detail)"
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

    static let listType = "WebBookmarkTypeList"
    static let leafType = "WebBookmarkTypeLeaf"
    /// Placeholders for things that are not bookmark storage: History, and on
    /// most macOS versions the Reading List container.
    static let proxyType = "WebBookmarkTypeProxy"
    /// The Reading List again, which on some versions is a plain list with this
    /// title instead of a proxy. A reading queue is not a filed bookmark, so it
    /// is skipped under either spelling.
    static let readingListTitle = "com.apple.ReadingList"

    // MARK: - Locating the file

    static func bookmarksURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Safari/Bookmarks.plist", directoryHint: .notDirectory)
    }

    /// The live bookmarks file, or nil when it is absent **or** unreadable. Use
    /// `isBlockedByFullDiskAccess(fileManager:)` to tell those two apart: only
    /// the second is something the user can fix.
    public static func defaultBookmarksURL(fileManager: FileManager = .default) -> URL? {
        let url = bookmarksURL(fileManager: fileManager)
        return fileManager.isReadableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Whether the file exists but macOS will not let this process read it.
    ///
    /// Measured on macOS 27 (Darwin 27.0.0) from an unsandboxed binary without
    /// Full Disk Access, against a real `~/Library/Safari/Bookmarks.plist`:
    ///
    /// - `stat()` succeeds and reports the true size, so
    ///   `fileExists(atPath:)` answers **true**.
    /// - `access()` fails, so `isReadableFile(atPath:)` answers **false**.
    /// - `open()` fails with `EPERM` (1) — *not* `EACCES`.
    /// - `Data(contentsOf:)` and `contentsOfDirectory` both throw
    ///   `NSCocoaErrorDomain` `NSFileReadNoPermissionError` (257, not 260,
    ///   which is `NSFileReadNoSuchFileError`) wrapping `NSPOSIXErrorDomain` 1.
    ///
    /// So "exists but is not readable" is a sound test here, and it is the one
    /// the UI needs *before* attempting a read — the card has to say "needs
    /// Full Disk Access" rather than silently offering the export path the way
    /// a Chromium profile refusal does.
    public static func isBlockedByFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let path = bookmarksURL(fileManager: fileManager).path(percentEncoded: false)
        return fileManager.fileExists(atPath: path)
            && !fileManager.isReadableFile(atPath: path)
    }

    /// Whether a read failed because macOS refused it rather than because the
    /// file is gone. Both the Cocoa code and the POSIX errno underneath it are
    /// accepted, and `EACCES` alongside the `EPERM` a TCC denial actually
    /// produces, because an ordinary permission bit would surface as the latter.
    static func isPermissionDenied(_ error: Swift.Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if isPOSIXDenial(nsError) { return true }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isPOSIXDenial(underlying)
    }

    private static func isPOSIXDenial(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain
            && (error.code == Int(EPERM) || error.code == Int(EACCES))
    }

    // MARK: - Importing

    public static func importBookmarks(fileManager: FileManager = .default) throws -> Result {
        guard let url = defaultBookmarksURL(fileManager: fileManager) else {
            throw isBlockedByFullDiskAccess(fileManager: fileManager)
                ? Error.permissionDenied
                : Error.bookmarksNotFound
        }
        return try importBookmarks(at: url)
    }

    public static func importBookmarks(at url: URL) throws -> Result {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Access can be revoked between the card offering Safari and the
            // click that loads it, so this is a live path, not a fallback.
            throw isPermissionDenied(error) ? Error.permissionDenied : Error.bookmarksNotFound
        }
        return try importBookmarks(plistData: data)
    }

    public static func importBookmarks(plistData data: Data) throws -> Result {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw Error.malformed(String(describing: error))
        }
        guard let root = object as? [String: Any] else {
            throw Error.malformed("the root is not a dictionary")
        }

        var bookmarks: [Bookmark] = []
        var seenIDs = Set<String>()
        var existingFolders: [String] = []
        var existingFolderSet = Set<String>()
        var summary = Summary()

        func walk(_ node: [String: Any], path: [String]) {
            let type = node["WebBookmarkType"] as? String
            let title = node["Title"] as? String
            guard type != proxyType, title != readingListTitle else { return }

            if type == leafType {
                guard let rawURL = node["URLString"] as? String, isWebURL(rawURL) else { return }

                let id = BookmarkID.make(forNormalizedURL: URLNormalizer.normalize(rawURL))
                guard seenIDs.insert(id).inserted else {
                    summary.duplicatesSkipped += 1
                    return
                }

                // The display name lives in the nested dictionary; the
                // top-level Title is a redundant copy that some entries carry
                // and some don't.
                let leafTitle = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                bookmarks.append(
                    Bookmark(
                        id: id,
                        title: (leafTitle ?? title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        url: rawURL,
                        originalFolderPath: path,
                        addedAt: nil
                    )
                )
                return
            }

            // A list, or the root itself — which carries children without
            // naming a type on every macOS version.
            if type == listType { summary.folderCount += 1 }
            var childPath = path
            if let title, !title.isEmpty {
                childPath.append(title)
                if existingFolderSet.insert(title).inserted { existingFolders.append(title) }
            }
            for child in node["Children"] as? [Any] ?? [] {
                guard let child = child as? [String: Any] else { continue }
                walk(child, path: childPath)
            }
        }

        walk(root, path: [])

        summary.bookmarkCount = bookmarks.count
        return Result(
            parse: ParseResult(bookmarks: bookmarks, existingFolders: existingFolders),
            summary: summary
        )
    }

    /// Safari files `file://` pages and Reading List leftovers alongside real
    /// bookmarks; neither is a page the pipeline can fetch or classify.
    static func isWebURL(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }
}
