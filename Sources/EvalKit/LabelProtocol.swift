import Foundation

public struct LabelKey: Hashable, Sendable, Codable {
    public var bookmarkID: String
    public var folder: String

    public init(bookmarkID: String, folder: String) {
        self.bookmarkID = bookmarkID
        self.folder = folder
    }
}

public enum Verdict: String, Codable, Sendable {
    case accept
    case reject
}

public struct Label: Codable, Sendable, Equatable {
    public var bookmarkID: String
    public var folder: String
    public var verdict: Verdict
    public var source: String
    public var note: String?
    public var labeledAt: Date

    public var key: LabelKey { LabelKey(bookmarkID: bookmarkID, folder: folder) }

    public init(
        bookmarkID: String,
        folder: String,
        verdict: Verdict,
        source: String = "human",
        note: String? = nil,
        labeledAt: Date = .now
    ) {
        self.bookmarkID = bookmarkID
        self.folder = folder
        self.verdict = verdict
        self.source = source
        self.note = note
        self.labeledAt = labeledAt
    }
}
