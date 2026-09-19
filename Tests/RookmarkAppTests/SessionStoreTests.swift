import Foundation
import RookmarkKit
import Testing

@testable import RookmarkApp

@Suite("Session staleness")
struct SessionStoreTests {

    private func bookmark(_ id: String) -> Bookmark {
        Bookmark(id: id, title: "Title \(id)", url: "https://example.com/\(id)")
    }

    private func row(_ id: String) -> SessionStore.StoredRow {
        .init(id: id, title: "Title \(id)", url: "https://example.com/\(id)",
              folder: "Development", confidence: 90, modelChoice: nil,
              included: true, accepted: nil)
    }

    private func snapshot(source: [String], classified: [String]) -> SessionStore.Snapshot {
        .init(savedAt: Date(timeIntervalSinceNow: -3600),
              sourceIDs: source,
              rows: classified.map(row),
              newFolders: [],
              completed: source.count == classified.count)
    }

    @Test("a finished run over an unchanged library is not stale")
    func clean() {
        let live = ["a", "b", "c"].map(bookmark)
        let state = SessionStore.staleness(
            of: snapshot(source: ["a", "b", "c"], classified: ["a", "b", "c"]),
            against: live
        )

        #expect(state.unclassified == 0)
        #expect(state.added == 0)
        #expect(state.removed == 0)
        #expect(!state.isStale)
    }

    @Test("a run stopped part-way reports what it never reached")
    func incomplete() {
        let live = ["a", "b", "c", "d"].map(bookmark)
        let state = SessionStore.staleness(
            of: snapshot(source: ["a", "b", "c", "d"], classified: ["a", "b"]),
            against: live
        )

        #expect(state.unclassified == 2)
        #expect(state.isIncomplete)
        #expect(state.isStale)
        #expect(!state.hasDrifted)
    }

    @Test("bookmarks added since the run are counted as drift")
    func added() {
        let live = ["a", "b", "c"].map(bookmark)
        let state = SessionStore.staleness(
            of: snapshot(source: ["a", "b"], classified: ["a", "b"]),
            against: live
        )

        #expect(state.added == 1)
        #expect(state.unclassified == 0, "a new bookmark is drift, not unfinished work")
        #expect(state.hasDrifted)
    }

    @Test("bookmarks deleted since the run are counted as drift")
    func removed() {
        let live = ["a"].map(bookmark)
        let state = SessionStore.staleness(
            of: snapshot(source: ["a", "b"], classified: ["a", "b"]),
            against: live
        )

        #expect(state.removed == 1)
        #expect(state.hasDrifted)
    }

    /// The trap: an item the run never classified, which the user then deleted
    /// from the browser. It is gone, so it is not outstanding work — counting it
    /// would leave Organize permanently offering to classify something absent.
    @Test("an unclassified bookmark that was since deleted is not outstanding work")
    func unclassifiedThenDeleted() {
        let live = ["a"].map(bookmark)
        let state = SessionStore.staleness(
            of: snapshot(source: ["a", "b"], classified: ["a"]),
            against: live
        )

        #expect(state.unclassified == 0)
        #expect(state.removed == 1)
        #expect(!state.isIncomplete)
    }

    @Test("drift and incompleteness are reported together")
    func both() {
        let live = ["a", "b", "c"].map(bookmark)
        let state = SessionStore.staleness(
            of: snapshot(source: ["a", "b"], classified: ["a"]),
            against: live
        )

        #expect(state.unclassified == 1)   // b, still present, never classified
        #expect(state.added == 1)          // c, new since the run
        #expect(state.isIncomplete)
        #expect(state.hasDrifted)
    }
}
