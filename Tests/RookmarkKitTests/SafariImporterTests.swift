import XCTest
@testable import RookmarkKit

final class SafariImporterTests: XCTestCase {

    /// Builds a Bookmarks.plist the way Safari does: one root list whose
    /// `Children` are `BookmarksBar`, `BookmarksMenu` and the proxies.
    private func makePlist(_ children: [[String: Any]]) throws -> Data {
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkFileVersion": 1,
            "Title": "",
            "Children": children,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    private func folder(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
        ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children]
    }

    /// A leaf as Safari writes it: the display name in the nested
    /// `URIDictionary`, optionally duplicated at the top level.
    private func bookmark(
        _ title: String?, _ url: String, topLevelTitle: String? = nil
    ) -> [String: Any] {
        var d: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url]
        // Safari keeps the URL under the empty-string key here as well.
        var uri: [String: Any] = ["": url]
        if let title { uri["title"] = title }
        d["URIDictionary"] = uri
        if let topLevelTitle { d["Title"] = topLevelTitle }
        return d
    }

    func testImportsNestedFolderPathOutermostFirst() throws {
        let data = try makePlist([
            folder("BookmarksBar", [
                folder("Dev", [bookmark("Swift", "https://swift.org")])
            ]),
            folder("BookmarksMenu", [bookmark("Example", "https://example.com")]),
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.count, 2)
        let bookmark = try XCTUnwrap(result.parse.bookmarks.first)
        // The root's empty title drops out; the path runs outermost -> innermost.
        XCTAssertEqual(bookmark.originalFolderPath, ["BookmarksBar", "Dev"])
        XCTAssertEqual(bookmark.url, "https://swift.org")
        XCTAssertEqual(result.parse.bookmarks.last?.originalFolderPath, ["BookmarksMenu"])
        XCTAssertEqual(result.parse.existingFolders, ["BookmarksBar", "Dev", "BookmarksMenu"])
        XCTAssertEqual(result.summary.folderCount, 4, "the root is a list too, plus the three named ones")
    }

    func testTitleComesFromURIDictionaryNotTheTopLevelKey() throws {
        let data = try makePlist([
            folder("BookmarksBar", [
                bookmark("The real one", "https://example.com/a", topLevelTitle: "Stale copy")
            ])
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["The real one"])
    }

    /// Some entries carry only the top-level `Title`, and some carry neither.
    func testFallsBackToTopLevelTitleThenToEmpty() throws {
        let data = try makePlist([
            folder("BookmarksBar", [
                bookmark(nil, "https://example.com/a", topLevelTitle: "Only at the top"),
                bookmark(nil, "https://example.com/b"),
            ])
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Only at the top", ""])
    }

    /// History and (on most macOS versions) the Reading List are proxies:
    /// placeholders, not bookmark storage. Nothing inside one is imported.
    func testSkipsProxyNodesAndTheirContents() throws {
        let data = try makePlist([
            folder("BookmarksBar", [bookmark("Kept", "https://example.com/kept")]),
            [
                "WebBookmarkType": "WebBookmarkTypeProxy",
                "Title": "History",
                "Children": [bookmark("Never", "https://example.com/history")],
            ],
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Kept"])
        XCTAssertFalse(result.parse.existingFolders.contains("History"))
    }

    /// On other versions the Reading List is a plain list, identified only by
    /// its title. A reading queue is not a bookmark the user filed.
    func testSkipsTheReadingListWhateverItsType() throws {
        let data = try makePlist([
            folder("BookmarksBar", [bookmark("Kept", "https://example.com/kept")]),
            folder("com.apple.ReadingList", [bookmark("Queued", "https://example.com/queued")]),
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Kept"])
        XCTAssertFalse(result.parse.existingFolders.contains("com.apple.ReadingList"))
    }

    func testSkipsNonHTTPSchemes() throws {
        let data = try makePlist([
            folder("BookmarksBar", [
                bookmark("Local", "file:///Users/rook/notes.html"),
                bookmark("Reader", "x-apple-reader://example"),
                bookmark("Real", "https://example.com"),
            ])
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Real"])
    }

    func testDeduplicatesByNormalizedURL() throws {
        let data = try makePlist([
            folder("BookmarksBar", [
                bookmark("First", "https://example.com/page"),
                bookmark("Dup w/ tracking", "https://example.com/page?utm_source=x"),
            ]),
            folder("BookmarksMenu", [
                bookmark("Dup in another folder", "https://www.example.com/page/")
            ]),
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["First"])
        XCTAssertEqual(result.summary.duplicatesSkipped, 2)
        XCTAssertEqual(result.summary.bookmarkCount, 1)
    }

    /// `Children` is an ordered array, so the same file has to import the same
    /// way every time — including the ids, which downstream batching keys off.
    func testImportIsDeterministic() throws {
        let children: [[String: Any]] = [
            folder("BookmarksBar", [bookmark("A", "https://example.com/a")]),
            folder("BookmarksMenu", [bookmark("B", "https://example.com/b")]),
        ]
        let first = try SafariImporter.importBookmarks(plistData: try makePlist(children))
        let second = try SafariImporter.importBookmarks(plistData: try makePlist(children))

        XCTAssertEqual(first.parse.bookmarks.map(\.title), ["A", "B"])
        XCTAssertEqual(first.parse.bookmarks.map(\.id), second.parse.bookmarks.map(\.id))
    }

    /// The format varies by macOS version, so a node this importer doesn't
    /// recognize is stepped over rather than failing the whole import.
    func testMalformedNodesAreSkippedNotThrown() throws {
        let data = try makePlist([
            folder("BookmarksBar", [
                ["WebBookmarkType": "WebBookmarkTypeLeaf"],              // no URLString
                ["Title": "typeless", "Children": [bookmark("Nested", "https://example.com/n")]],
                bookmark("Real", "https://example.com/real"),
            ])
        ])

        let result = try SafariImporter.importBookmarks(plistData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Nested", "Real"])
    }

    func testNonDictionaryRootThrows() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["not", "a", "dictionary"], format: .binary, options: 0
        )
        XCTAssertThrowsError(try SafariImporter.importBookmarks(plistData: data))
    }

    // MARK: classifying a refused read
    //
    // A live TCC denial cannot be reproduced in a test run — it depends on
    // whether this Mac has granted Full Disk Access to the test binary — so the
    // errors observed from one are reconstructed instead. What was measured on
    // macOS 27 from an unsandboxed process without the grant: NSCocoaErrorDomain
    // 257 (NSFileReadNoPermissionError) wrapping NSPOSIXErrorDomain 1 (EPERM).

    func testCocoaReadNoPermissionIsAPermissionDenial() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )
        XCTAssertTrue(SafariImporter.isPermissionDenied(error))
    }

    /// The POSIX errno alone, for a path that surfaces it unwrapped.
    func testBarePOSIXDenialsAreRecognized() {
        XCTAssertTrue(SafariImporter.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        ))
        XCTAssertTrue(SafariImporter.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        ))
    }

    /// The distinction the `Error` cases exist for: a missing file is not
    /// something the user can fix in System Settings. 260 is
    /// NSFileReadNoSuchFileError — a digit away from the denial code, and the
    /// reason this is asserted rather than assumed.
    func testMissingFileIsNotAPermissionDenial() {
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]
        )
        XCTAssertFalse(SafariImporter.isPermissionDenied(error))
        XCTAssertFalse(SafariImporter.isPermissionDenied(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        ))
    }

    /// A read of a path that isn't there reports "not found", never the
    /// actionable case — the whole point of keeping them apart.
    func testMissingFileImportsAsNotFound() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-no-safari-\(UUID().uuidString)/Bookmarks.plist")
        XCTAssertThrowsError(try SafariImporter.importBookmarks(at: missing)) { error in
            guard case SafariImporter.Error.bookmarksNotFound = error else {
                XCTFail("expected .bookmarksNotFound, got \(error)")
                return
            }
        }
    }
}
