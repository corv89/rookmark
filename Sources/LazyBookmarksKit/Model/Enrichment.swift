import Foundation

public struct Enrichment: Sendable, Equatable, Codable {
    public var bookmarkID: String
    public var metaDescription: String?
    public var isDeadLink: Bool
    public var httpStatus: Int?
    public var fetchedAt: Date

    public init(
        bookmarkID: String,
        metaDescription: String? = nil,
        isDeadLink: Bool = false,
        httpStatus: Int? = nil,
        fetchedAt: Date = .now
    ) {
        self.bookmarkID = bookmarkID
        self.metaDescription = metaDescription
        self.isDeadLink = isDeadLink
        self.httpStatus = httpStatus
        self.fetchedAt = fetchedAt
    }
}
