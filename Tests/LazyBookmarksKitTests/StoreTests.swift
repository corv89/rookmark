import Foundation
import Testing
@testable import LazyBookmarksKit

@Suite("Store")
struct StoreTests {

    func makeStore() throws -> Store {
        let path = NSTemporaryDirectory() + "lazybm_test_\(UUID().uuidString).sqlite"
        return try Store(path: path)
    }

    @Test("create run and upsert bookmarks")
    func upsertAndFetch() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        let bookmarks = [
            Bookmark(id: "a", title: "Swift", url: "https://swift.org"),
            Bookmark(id: "b", title: "Apple", url: "https://apple.com"),
        ]
        try store.upsert(bookmarks, runID: runID)
        let all = try store.all(runID: runID)
        #expect(all.count == 2)
    }

    @Test("uncommitted returns only uncommitted bookmarks")
    func uncommitted() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        let bookmarks = [
            Bookmark(id: "a", title: "Swift", url: "https://swift.org"),
            Bookmark(id: "b", title: "Apple", url: "https://apple.com"),
        ]
        try store.upsert(bookmarks, runID: runID)

        let decisions = [Classifier.Decision(bookmarkID: "a", folder: "Dev", confidence: 90)]
        try store.commit(decisions, runID: runID)

        let pending = try store.uncommitted(runID: runID)
        #expect(pending.count == 1)
        #expect(pending[0].id == "b")
    }

    @Test("commit applies decisions to bookmarks")
    func commit() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        try store.upsert([Bookmark(id: "a", title: "X", url: "https://x.com")], runID: runID)

        try store.commit([Classifier.Decision(bookmarkID: "a", folder: "Tech", confidence: 85)], runID: runID)

        let all = try store.all(runID: runID)
        #expect(all[0].assignedFolder == "Tech")
        #expect(all[0].confidence == 85)
    }

    @Test("snapshot and undo restores previous state")
    func snapshotUndo() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        try store.upsert([Bookmark(id: "a", title: "X", url: "https://x.com")], runID: runID)

        try store.snapshot(runID: runID)

        try store.commit([Classifier.Decision(bookmarkID: "a", folder: "Tech", confidence: 90)], runID: runID)
        let afterCommit = try store.all(runID: runID)
        #expect(afterCommit[0].assignedFolder == "Tech")

        let ok = try store.undoLast(runID: runID)
        #expect(ok)

        let afterUndo = try store.all(runID: runID)
        #expect(afterUndo[0].assignedFolder == nil)
    }

    @Test("undo on empty snapshots returns false")
    func undoEmpty() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        let ok = try store.undoLast(runID: runID)
        #expect(!ok)
    }
}
