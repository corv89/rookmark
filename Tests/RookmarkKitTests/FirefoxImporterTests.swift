import GRDB
import XCTest
@testable import RookmarkKit

final class FirefoxImporterTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        temporaryFiles = []
        super.tearDown()
    }

    /// One `moz_bookmarks` row. Folders and separators carry no `url`; a
    /// bookmark's URL is written into `moz_places` and joined back by `fk`.
    private struct Entry {
        var id: Int64
        var type: Int
        var parent: Int64?
        var title: String?
        var url: String?
        var dateAdded: Double?
        var guid: String?
    }

    private func folder(_ id: Int64, _ title: String, parent: Int64?, guid: String? = nil) -> Entry {
        Entry(id: id, type: 2, parent: parent, title: title, guid: guid)
    }

    private func bookmark(
        _ id: Int64, _ title: String, _ url: String, parent: Int64?, dateAdded: Double? = nil
    ) -> Entry {
        Entry(id: id, type: 1, parent: parent, title: title, url: url, dateAdded: dateAdded)
    }

    private func separator(_ id: Int64, parent: Int64?) -> Entry {
        Entry(id: id, type: 3, parent: parent, title: nil)
    }

    /// Writes a places.sqlite with just the two tables the importer reads, then
    /// hands back its path — the importer opens it read-only from there, which
    /// is exactly what it does against a live Firefox profile.
    private func makePlaces(_ entries: [Entry]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-places-\(UUID().uuidString).sqlite")
        temporaryFiles.append(url)

        let queue = try DatabaseQueue(path: url.path(percentEncoded: false))
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR)")
            try db.execute(sql: """
                CREATE TABLE moz_bookmarks (
                    id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER,
                    position INTEGER, title LONGVARCHAR, dateAdded INTEGER, guid TEXT
                )
                """)
            for entry in entries {
                var placeID: Int64?
                if let url = entry.url {
                    // Places ids are independent of bookmark ids; offsetting
                    // keeps the fixture honest about that.
                    placeID = entry.id + 1000
                    try db.execute(
                        sql: "INSERT INTO moz_places (id, url) VALUES (?, ?)",
                        arguments: [placeID, url]
                    )
                }
                try db.execute(
                    sql: """
                        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, dateAdded, guid)
                        VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                        """,
                    arguments: [
                        entry.id, entry.type, placeID, entry.parent,
                        entry.title, entry.dateAdded.map { Int64($0) }, entry.guid,
                    ]
                )
            }
        }
        return url
    }

    /// The root layout Firefox itself creates: an untitled root with the four
    /// places roots under it.
    private var roots: [Entry] {
        [
            folder(1, "", parent: nil, guid: "root________"),
            folder(2, "Bookmarks Menu", parent: 1, guid: "menu________"),
            folder(3, "Bookmarks Toolbar", parent: 1, guid: "toolbar_____"),
            folder(4, "Tags", parent: 1, guid: FirefoxImporter.tagsRootGUID),
            folder(5, "Other Bookmarks", parent: 1, guid: "unfiled_____"),
        ]
    }

    func testImportsNestedFolderPathOutermostFirst() throws {
        let url = try makePlaces(roots + [
            folder(10, "Dev", parent: 3),
            bookmark(11, "Swift", "https://swift.org", parent: 10),
        ])

        let result = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(result.parse.bookmarks.count, 1)
        let bookmark = try XCTUnwrap(result.parse.bookmarks.first)
        // The untitled root drops out; the path runs outermost -> innermost.
        XCTAssertEqual(bookmark.originalFolderPath, ["Bookmarks Toolbar", "Dev"])
        XCTAssertEqual(bookmark.url, "https://swift.org")
    }

    func testDateAddedIsMicrosecondsNotSeconds() throws {
        // 1_726_938_530_117_458 µs -> 2024-09-21
        let url = try makePlaces(roots + [
            bookmark(10, "T", "https://example.com", parent: 5, dateAdded: 1_726_938_530_117_458)
        ])

        let result = try FirefoxImporter.importBookmarks(at: url)

        let added = try XCTUnwrap(result.parse.bookmarks.first?.addedAt)
        let year = Calendar(identifier: .gregorian).component(.year, from: added)
        XCTAssertEqual(year, 2024, "µs treated as ms would land in 56680, as seconds far further still")
    }

    func testSkipsSeparators() throws {
        let url = try makePlaces(roots + [
            bookmark(10, "A", "https://example.com/a", parent: 3),
            separator(11, parent: 3),
            bookmark(12, "B", "https://example.com/b", parent: 3),
        ])

        let result = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["A", "B"])
    }

    /// The tags root's children look exactly like folders full of bookmarks but
    /// are Firefox's tag index: the same page appears once per tag it carries.
    func testSkipsTagsRootSubtree() throws {
        let url = try makePlaces(roots + [
            bookmark(10, "Filed", "https://example.com/filed", parent: 5),
            folder(11, "swift", parent: 4),
            bookmark(12, "Tagged", "https://example.com/tagged", parent: 11),
        ])

        let result = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Filed"])
        XCTAssertFalse(result.parse.existingFolders.contains("swift"), "a tag is not a folder")
        XCTAssertFalse(result.parse.existingFolders.contains("Tags"))
        XCTAssertEqual(
            result.summary.folderCount, 4,
            "the untitled root and the three non-tag places roots; the tags root and its tag are not folders"
        )
    }

    func testSkipsPlaceAndOtherNonHTTPSchemes() throws {
        let url = try makePlaces(roots + [
            bookmark(10, "Recent Tags", "place:type=6&sort=14", parent: 2),
            bookmark(11, "Bookmarklet", "javascript:void(0)", parent: 2),
            bookmark(12, "Real", "https://example.com", parent: 2),
        ])

        let result = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["Real"])
    }

    func testDeduplicatesByNormalizedURL() throws {
        let url = try makePlaces(roots + [
            bookmark(10, "First", "https://example.com/page", parent: 3),
            bookmark(11, "Dup w/ tracking", "https://example.com/page?utm_source=x", parent: 5),
        ])

        let result = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(result.parse.bookmarks.map(\.title), ["First"])
        XCTAssertEqual(result.summary.duplicatesSkipped, 1)
    }

    /// Ordered by row id, so two reads of the same database agree.
    func testImportIsDeterministic() throws {
        let url = try makePlaces(roots + [
            bookmark(12, "C", "https://example.com/c", parent: 3),
            bookmark(10, "A", "https://example.com/a", parent: 3),
            bookmark(11, "B", "https://example.com/b", parent: 3),
        ])

        let first = try FirefoxImporter.importBookmarks(at: url)
        let second = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(first.parse.bookmarks.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(first.parse.bookmarks.map(\.id), second.parse.bookmarks.map(\.id))
    }

    /// WAL is how a live Firefox and this importer share the file, so the
    /// read-only open has to work against a WAL database with an open writer.
    func testReadsAWALDatabaseWhileAWriterHoldsIt() throws {
        let url = try makePlaces(roots + [
            bookmark(10, "A", "https://example.com/a", parent: 3)
        ])
        // On the connection, not inside a transaction: SQLite refuses to change
        // journal mode from within one.
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        let writer = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
        try writer.write { db in
            try db.execute(sql: "UPDATE moz_bookmarks SET position = 1 WHERE id = 10")
        }

        let result = try FirefoxImporter.importBookmarks(at: url)

        XCTAssertEqual(result.parse.bookmarks.count, 1)
        withExtendedLifetime(writer) {}
    }

    // MARK: locating the profile

    private func makeFirefoxRoot(
        profiles: String? = nil, installs: String? = nil, directories: [String]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-firefox-\(UUID().uuidString)", directoryHint: .isDirectory)
        temporaryFiles.append(root)

        for directory in directories {
            let profile = root.appending(path: directory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data().write(to: profile.appending(path: "places.sqlite"))
        }
        if let profiles {
            try profiles.write(to: root.appending(path: "profiles.ini"), atomically: true, encoding: .utf8)
        }
        if let installs {
            try installs.write(to: root.appending(path: "installs.ini"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Since Firefox 67 the per-installation file is what actually decides,
    /// and it names the profile by path rather than with a flag.
    func testInstallsINIWinsOverProfilesINI() throws {
        let root = try makeFirefoxRoot(
            profiles: """
            [Profile0]
            Name=default
            IsRelative=1
            Path=Profiles/old.default
            Default=1
            """,
            installs: """
            [4F96D1932A9F858E]
            Default=Profiles/new.default-release
            Locked=1
            """,
            directories: ["Profiles/old.default", "Profiles/new.default-release"]
        )

        let places = try XCTUnwrap(FirefoxImporter.placesURL(inRoot: root))
        XCTAssertEqual(places.deletingLastPathComponent().lastPathComponent, "new.default-release")
    }

    func testProfilesINIDefaultFlag() throws {
        let root = try makeFirefoxRoot(
            profiles: """
            [General]
            StartWithLastProfile=1

            [Profile0]
            Name=dev
            IsRelative=1
            Path=Profiles/dev

            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/chosen.default
            Default=1
            """,
            directories: ["Profiles/dev", "Profiles/chosen.default"]
        )

        let places = try XCTUnwrap(FirefoxImporter.placesURL(inRoot: root))
        XCTAssertEqual(places.deletingLastPathComponent().lastPathComponent, "chosen.default")
    }

    /// Nothing marked anywhere: the most recently touched profile is the best
    /// guess left.
    func testFallsBackToMostRecentlyModifiedProfile() throws {
        let root = try makeFirefoxRoot(directories: ["Profiles/stale", "Profiles/fresh"])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: root.appending(path: "Profiles/stale").path(percentEncoded: false)
        )

        let places = try XCTUnwrap(FirefoxImporter.placesURL(inRoot: root))
        XCTAssertEqual(places.deletingLastPathComponent().lastPathComponent, "fresh")
    }

    func testNoProfileIsNil() throws {
        let root = try makeFirefoxRoot(directories: [])
        XCTAssertNil(FirefoxImporter.placesURL(inRoot: root))
    }

    // MARK: classifying a refused read
    //
    // A live TCC denial cannot be reproduced in a test run, so `chmod 000` on
    // a real file stands in for it — same "exists but access() refuses it"
    // shape `isBlockedByFullDiskAccess` and `importBookmarks(at:)` probe for.

    func testUnreadableProfilesINIReportsBlockedByFullDiskAccess() throws {
        let root = try makeFirefoxRoot(profiles: "[Profile0]\nDefault=1\nPath=stale\n", directories: ["stale"])
        let profilesINI = root.appending(path: "profiles.ini").path(percentEncoded: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profilesINI) }

        XCTAssertFalse(FirefoxImporter.isBlockedByFullDiskAccess(inRoot: root), "readable so far: not blocked")

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: profilesINI)

        XCTAssertTrue(FirefoxImporter.isBlockedByFullDiskAccess(inRoot: root))
    }

    func testNoProfilesINIAtAllIsNotBlocked() throws {
        let root = try makeFirefoxRoot(directories: [])
        XCTAssertFalse(FirefoxImporter.isBlockedByFullDiskAccess(inRoot: root), "nothing there at all is 'not installed', not 'blocked'")
    }

    func testImportAtURLThrowsPermissionDeniedWhenPlacesIsUnreadable() throws {
        let url = try makePlaces([bookmark(1, "A", "https://example.com/a", parent: nil)])
        let path = url.path(percentEncoded: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

        XCTAssertThrowsError(try FirefoxImporter.importBookmarks(at: url)) { error in
            guard case FirefoxImporter.Error.permissionDenied = error else {
                XCTFail("expected .permissionDenied, got \(error)")
                return
            }
        }
    }

    /// A path that was simply never there classifies differently from one
    /// that exists but is refused: only the second is fixable in Settings.
    func testMissingPlacesFileIsNotPermissionDenied() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-firefox-missing-\(UUID().uuidString)/places.sqlite")
        XCTAssertThrowsError(try FirefoxImporter.importBookmarks(at: missing)) { error in
            guard case FirefoxImporter.Error.permissionDenied = error else { return }
            XCTFail("a missing file must not classify as permissionDenied, got \(error)")
        }
    }
}
