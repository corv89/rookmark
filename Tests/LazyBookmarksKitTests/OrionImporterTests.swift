import XCTest
@testable import LazyBookmarksKit

final class OrionImporterTests: XCTestCase {

    /// Builds a favourites.plist the way Orion does: a flat dict keyed by id.
    private func makePlist(_ entries: [String: [String: Any]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    private func folder(_ id: String, _ title: String, parent: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["id": id, "type": "folder", "title": title, "index": 0]
        if let parent { d["parentId"] = parent }
        return d
    }

    private func bookmark(
        _ id: String, _ title: String, _ url: String, parent: String?, dateAdded: Double? = nil
    ) -> [String: Any] {
        var d: [String: Any] = ["id": id, "type": "bookmark", "title": title, "url": url, "index": 0]
        if let parent { d["parentId"] = parent }
        if let dateAdded { d["dateAdded"] = dateAdded }
        return d
    }

    func testImportsNestedFolderPathOutermostFirst() throws {
        let data = try makePlist([
            "0": folder("0", ""),                          // invisible root, empty title
            "1": folder("1", "Bookmarks Bar", parent: "0"),
            "9": folder("9", "Dev", parent: "1"),
            "a": bookmark("a", "Swift", "https://swift.org", parent: "9"),
        ])

        let result = try OrionImporter.importFavourites(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.count, 1)
        let bookmark = try XCTUnwrap(result.parse.bookmarks.first)
        // Root's empty title is dropped; path runs outermost -> innermost.
        XCTAssertEqual(bookmark.originalFolderPath, ["Bookmarks Bar", "Dev"])
        XCTAssertEqual(bookmark.url, "https://swift.org")
        XCTAssertEqual(result.summary.withResolvedFolder, 1)
        XCTAssertEqual(result.summary.orphanedFolderReferences, 0)
        XCTAssertEqual(result.summary.missingFolderIDs, 0)
    }

    /// The case that dominates a real profile after a partial import: the folder
    /// entries are gone but the bookmarks still reference them.
    func testOrphanedParentImportsAtRootAndIsCounted() throws {
        let data = try makePlist([
            "0": folder("0", ""),
            "a": bookmark("a", "Orphan", "https://example.com/a", parent: "MISSING-UUID"),
            "b": bookmark("b", "Also orphan", "https://example.com/b", parent: "MISSING-UUID"),
            "c": bookmark("c", "Rooted", "https://example.com/c", parent: "0"),
        ])

        let result = try OrionImporter.importFavourites(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.count, 3)
        for bookmark in result.parse.bookmarks where bookmark.title.contains("orphan") {
            XCTAssertEqual(bookmark.originalFolderPath, [], "orphans import at root, never dropped")
        }
        XCTAssertEqual(result.summary.orphanedFolderReferences, 2)
        XCTAssertEqual(result.summary.withResolvedFolder, 1)
        XCTAssertEqual(result.summary.missingFolderIDs, 1, "two bookmarks, one missing folder id")
    }

    func testParentCycleTerminates() throws {
        let data = try makePlist([
            "x": folder("x", "X", parent: "y"),
            "y": folder("y", "Y", parent: "x"),
            "a": bookmark("a", "Looped", "https://example.com/loop", parent: "x"),
        ])

        let result = try OrionImporter.importFavourites(plistData: data)

        let bookmark = try XCTUnwrap(result.parse.bookmarks.first)
        XCTAssertEqual(Set(bookmark.originalFolderPath), ["X", "Y"], "each folder visited once")
    }

    func testDateAddedIsMillisecondsNotSeconds() throws {
        // 1726938530117.458 ms -> 2024-09-21
        let data = try makePlist([
            "a": bookmark("a", "T", "https://example.com", parent: nil, dateAdded: 1_726_938_530_117.458)
        ])

        let result = try OrionImporter.importFavourites(plistData: data)

        let added = try XCTUnwrap(result.parse.bookmarks.first?.addedAt)
        let year = Calendar(identifier: .gregorian).component(.year, from: added)
        XCTAssertEqual(year, 2024, "ms treated as seconds would land in 56680")
    }

    func testSkipsFoldersAndEntriesWithoutURL() throws {
        let data = try makePlist([
            "0": folder("0", "Root"),
            "1": folder("1", "Empty folder", parent: "0"),
            "a": bookmark("a", "No url", "", parent: "0"),
            "b": bookmark("b", "Real", "https://example.com", parent: "0"),
        ])

        let result = try OrionImporter.importFavourites(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Real"])
        XCTAssertEqual(result.summary.folderCount, 2)
        XCTAssertEqual(result.parse.existingFolders, ["Root", "Empty folder"])
    }

    func testDeduplicatesByNormalizedURL() throws {
        let data = try makePlist([
            "a": bookmark("a", "First", "https://example.com/page", parent: nil),
            "b": bookmark("b", "Dup w/ tracking", "https://example.com/page?utm_source=x", parent: nil),
        ])

        let result = try OrionImporter.importFavourites(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.count, 1)
        XCTAssertEqual(result.summary.duplicatesSkipped, 1)
    }

    func testImportIsDeterministic() throws {
        let entries: [String: [String: Any]] = [
            "c": bookmark("c", "C", "https://example.com/c", parent: nil),
            "a": bookmark("a", "A", "https://example.com/a", parent: nil),
            "b": bookmark("b", "B", "https://example.com/b", parent: nil),
        ]
        let first = try OrionImporter.importFavourites(plistData: try makePlist(entries))
        let second = try OrionImporter.importFavourites(plistData: try makePlist(entries))

        XCTAssertEqual(first.parse.bookmarks.map(\.id), second.parse.bookmarks.map(\.id))
        XCTAssertEqual(first.parse.bookmarks.map(\.title), ["A", "B", "C"])
    }

    func testMalformedPlistThrows() throws {
        let notADict = try PropertyListSerialization.data(
            fromPropertyList: ["just", "an", "array"], format: .binary, options: 0
        )
        XCTAssertThrowsError(try OrionImporter.importFavourites(plistData: notADict))
    }
}
