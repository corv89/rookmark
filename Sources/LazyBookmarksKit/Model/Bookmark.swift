import Foundation

/// A single bookmark. `id` is a stable, content-derived identifier (see
/// `BookmarkID`) so that re-importing the same export, deduping, and resuming
/// are all deterministic across runs.
public struct Bookmark: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public var title: String
    public var url: String
    /// Folder path the bookmark lived in *in the source export*, outermost first.
    public var originalFolderPath: [String]
    public var addedAt: Date?

    /// Filled in by the pipeline.
    public var assignedFolder: String?
    public var confidence: Int?

    public init(
        id: String,
        title: String,
        url: String,
        originalFolderPath: [String] = [],
        addedAt: Date? = nil,
        assignedFolder: String? = nil,
        confidence: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.originalFolderPath = originalFolderPath
        self.addedAt = addedAt
        self.assignedFolder = assignedFolder
        self.confidence = confidence
    }

    /// Registrable domain (host minus leading `www.`), used in prompts instead
    /// of the full URL to save precious context tokens.
    public var domain: String {
        guard let host = URL(string: url)?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Output of the Netscape HTML parser.
public struct ParseResult: Sendable, Equatable {
    public var bookmarks: [Bookmark]
    /// Distinct folder names already present in the export (deepest names only),
    /// used to seed the taxonomy in `--preserve` mode.
    public var existingFolders: [String]

    public init(bookmarks: [Bookmark], existingFolders: [String]) {
        self.bookmarks = bookmarks
        self.existingFolders = existingFolders
    }
}

/// A flat, single-level set of topic folders. v1 is intentionally flat — no
/// nested taxonomy — to keep prompts inside the 4 096-token budget.
public struct Taxonomy: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        public var name: String
        public var rationale: String
        public init(name: String, rationale: String) {
            self.name = name
            self.rationale = rationale
        }
    }

    public var folders: [Folder]
    /// Sentinel for items the model cannot confidently place.
    public static let unsorted = "Unsorted"

    public init(folders: [Folder]) { self.folders = folders }

    public var names: [String] { folders.map(\.name) }

    /// All names the classifier is allowed to emit (taxonomy + sentinel).
    public var allowedFolderNames: [String] { names + [Self.unsorted] }
}
