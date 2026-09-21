import XCTest
@testable import RookmarkKit

final class ChromiumImporterTests: XCTestCase {

    /// Builds a Bookmarks file the way Chrome does: three named roots, each a
    /// folder node, with `date_added` written as a decimal string.
    private func makeBookmarks(_ roots: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["roots": roots, "version": 1])
    }

    private func folder(_ name: String, _ children: [[String: Any]]) -> [String: Any] {
        ["type": "folder", "name": name, "children": children]
    }

    private func bookmark(_ name: String, _ url: String, dateAdded: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["type": "url", "name": name, "url": url]
        if let dateAdded { d["date_added"] = dateAdded }
        return d
    }

    func testImportsNestedFolderPathOutermostFirst() throws {
        let data = try makeBookmarks([
            "bookmark_bar": folder("Bookmarks bar", [
                folder("Dev", [bookmark("Swift", "https://swift.org")])
            ]),
            "other": folder("Other bookmarks", []),
            "synced": folder("Mobile bookmarks", []),
        ])

        let result = try ChromiumImporter.importBookmarks(jsonData: data)

        XCTAssertEqual(result.parse.bookmarks.count, 1)
        let bookmark = try XCTUnwrap(result.parse.bookmarks.first)
        XCTAssertEqual(bookmark.originalFolderPath, ["Bookmarks bar", "Dev"])
        XCTAssertEqual(bookmark.url, "https://swift.org")
        XCTAssertEqual(result.summary.folderCount, 4, "the three roots are folders too, plus Dev")
        XCTAssertEqual(result.parse.existingFolders, ["Bookmarks bar", "Dev", "Other bookmarks", "Mobile bookmarks"])
    }

    func testDateAddedIsMicrosecondsSince1601NotUnix() throws {
        // 13_350_000_000_000_000 µs since 1601-01-01 -> 2024-01-17.
        let data = try makeBookmarks([
            "bookmark_bar": folder("Bookmarks bar", [
                bookmark("T", "https://example.com", dateAdded: "13350000000000000")
            ])
        ])

        let result = try ChromiumImporter.importBookmarks(jsonData: data)

        let added = try XCTUnwrap(result.parse.bookmarks.first?.addedAt)
        let year = Calendar(identifier: .gregorian).component(.year, from: added)
        XCTAssertEqual(year, 2024, "read against the Unix epoch it would land in 2393")
    }

    func testSkipsNonHTTPSchemes() throws {
        let data = try makeBookmarks([
            "bookmark_bar": folder("Bookmarks bar", [
                bookmark("Bookmarklet", "javascript:void(0)"),
                bookmark("Settings", "chrome://settings"),
                bookmark("Local", "file:///Users/rook/notes.html"),
                bookmark("Real", "https://example.com"),
            ])
        ])

        let result = try ChromiumImporter.importBookmarks(jsonData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Real"])
    }

    func testDeduplicatesByNormalizedURL() throws {
        let data = try makeBookmarks([
            "bookmark_bar": folder("Bookmarks bar", [
                bookmark("First", "https://example.com/page"),
                bookmark("Dup w/ tracking", "https://example.com/page?utm_source=x"),
            ]),
            "other": folder("Other bookmarks", [
                bookmark("Dup in another folder", "https://www.example.com/page/")
            ]),
        ])

        let result = try ChromiumImporter.importBookmarks(jsonData: data)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["First"])
        XCTAssertEqual(result.summary.duplicatesSkipped, 2)
        XCTAssertEqual(result.summary.bookmarkCount, 1)
    }

    /// The roots are read in a fixed order, so the JSON object's key order —
    /// which carries no meaning — cannot reorder the import.
    func testImportIsDeterministic() throws {
        let roots: [String: Any] = [
            "synced": folder("Mobile bookmarks", [bookmark("C", "https://example.com/c")]),
            "bookmark_bar": folder("Bookmarks bar", [bookmark("A", "https://example.com/a")]),
            "other": folder("Other bookmarks", [bookmark("B", "https://example.com/b")]),
        ]
        let first = try ChromiumImporter.importBookmarks(jsonData: try makeBookmarks(roots))
        let second = try ChromiumImporter.importBookmarks(jsonData: try makeBookmarks(roots))

        XCTAssertEqual(first.parse.bookmarks.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(first.parse.bookmarks.map(\.id), second.parse.bookmarks.map(\.id))
    }

    func testMalformedJSONThrows() throws {
        let noRoots = try JSONSerialization.data(withJSONObject: ["version": 1])
        XCTAssertThrowsError(try ChromiumImporter.importBookmarks(jsonData: noRoots))
    }

    // MARK: locating the profile

    private func makeProfile(
        localState: [String: Any]?, profileDirectory: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-chromium-\(UUID().uuidString)", directoryHint: .isDirectory)
        let profile = root.appending(path: profileDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appending(path: "Bookmarks"))
        if let localState {
            try JSONSerialization.data(withJSONObject: localState)
                .write(to: root.appending(path: "Local State"))
        }
        return root
    }

    func testLastUsedProfileFromLocalStateWins() throws {
        let root = try makeProfile(
            localState: ["profile": ["last_used": "Profile 2"]], profileDirectory: "Profile 2"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try XCTUnwrap(ChromiumImporter.bookmarksURL(inRoot: root))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Profile 2")
    }

    /// A one-profile install often has no Local State key at all, and its
    /// directory is literally `Default`.
    func testFallsBackToDefaultProfile() throws {
        let root = try makeProfile(localState: nil, profileDirectory: "Default")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try XCTUnwrap(ChromiumImporter.bookmarksURL(inRoot: root))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Default")
    }

    func testNoProfileIsNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-chromium-missing-\(UUID().uuidString)")
        XCTAssertNil(ChromiumImporter.bookmarksURL(inRoot: root))
    }

    /// The real-world case this guards: Chromium can leave `last_used`
    /// pointing at `System Profile` (no real bookmarks in it) when the
    /// browser was last closed on its profile-picker screen rather than
    /// inside an actual profile. A single guess with nothing to fall back to
    /// then reports "not installed" even with a real, readable Default
    /// profile sitting right there — the bug behind a live Brave profile
    /// silently demoting to the export card once Full Disk Access was
    /// actually granted.
    func testFallsBackWhenLastUsedProfileHasNoBookmarksFile() throws {
        let root = try makeProfile(
            localState: ["profile": ["last_used": "System Profile"]], profileDirectory: "Default"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        // "System Profile" is only named by Local State here, never actually
        // created as a directory — the exact shape of the real failure.

        let url = try XCTUnwrap(ChromiumImporter.bookmarksURL(inRoot: root))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Default")
    }

    /// Neither `last_used` nor `Default` pan out; only a scan of whatever
    /// profile directories actually exist finds the real one.
    func testFallsBackToAnotherProfileWhenDefaultAlsoHasNoBookmarks() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-chromium-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile1 = root.appending(path: "Profile 1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile1, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile1.appending(path: "Bookmarks"))

        let url = try XCTUnwrap(ChromiumImporter.bookmarksURL(inRoot: root))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Profile 1")
    }

    // MARK: classifying a refused read
    //
    // A live TCC denial cannot be reproduced in a test run, so `chmod 000` on
    // a real file stands in for it: same "exists but access() refuses it"
    // shape `isBlockedByFullDiskAccess` and `importBookmarks(at:for:)` probe
    // for, without depending on this Mac's actual Full Disk Access grant.

    func testUnreadableLocalStateReportsBlockedByFullDiskAccess() throws {
        let root = try makeProfile(localState: ["profile": ["last_used": "Default"]], profileDirectory: "Default")
        let localState = root.appending(path: "Local State").path(percentEncoded: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localState)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertFalse(ChromiumImporter.isBlockedByFullDiskAccess(inRoot: root), "readable so far: not blocked")

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: localState)

        XCTAssertTrue(ChromiumImporter.isBlockedByFullDiskAccess(inRoot: root))
    }

    func testNoLocalStateAtAllIsNotBlocked() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-chromium-missing-\(UUID().uuidString)")
        XCTAssertFalse(ChromiumImporter.isBlockedByFullDiskAccess(inRoot: root), "nothing there at all is 'not installed', not 'blocked'")
    }

    func testImportAtURLThrowsPermissionDeniedWhenBookmarksIsUnreadable() throws {
        let root = try makeProfile(localState: nil, profileDirectory: "Default")
        let bookmarks = root.appending(path: "Default/Bookmarks")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: bookmarks.path(percentEncoded: false)
            )
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: bookmarks.path(percentEncoded: false)
        )

        XCTAssertThrowsError(try ChromiumImporter.importBookmarks(at: bookmarks, for: .brave)) { error in
            guard case ChromiumImporter.Error.permissionDenied(.brave) = error else {
                XCTFail("expected .permissionDenied(.brave), got \(error)")
                return
            }
        }
    }

    /// A path that was simply never there classifies differently from one
    /// that exists but is refused: only the second is fixable in Settings.
    func testMissingBookmarksFileIsMalformedNotPermissionDenied() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-chromium-missing-\(UUID().uuidString)/Bookmarks")
        XCTAssertThrowsError(try ChromiumImporter.importBookmarks(at: missing, for: .chrome)) { error in
            guard case ChromiumImporter.Error.permissionDenied = error else { return }
            XCTFail("a missing file must not classify as permissionDenied, got \(error)")
        }
    }
}
