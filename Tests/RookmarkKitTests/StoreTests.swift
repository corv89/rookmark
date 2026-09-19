import Foundation
import Testing
@testable import RookmarkKit

@Suite("Store")
struct StoreTests {

    func makeStore() throws -> Store {
        let path = NSTemporaryDirectory() + "rookmark_test_\(UUID().uuidString).sqlite"
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

    @Test("loadTaxonomy decodes v2 envelope with rationales")
    func loadTaxonomyV2() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        let envelope = TaxonomyEnvelope(v: 2, folders: [
            .init(name: "News", rationale: "Current events"),
            .init(name: "Tech", rationale: "Software and hardware"),
        ])
        let json = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!
        try store.finishRun(runID, taxonomyJSON: json)

        let t = try store.loadTaxonomy(runID: runID)
        #expect(t != nil)
        #expect(t!.folders.count == 2)
        #expect(t!.folders[0].name == "News")
        #expect(t!.folders[0].rationale == "Current events")
        #expect(t!.folders[1].name == "Tech")
    }

    @Test("loadTaxonomy decodes legacy names-only array")
    func loadTaxonomyLegacy() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        let json = String(data: try JSONEncoder().encode(["News", "Tech"]), encoding: .utf8)!
        try store.finishRun(runID, taxonomyJSON: json)

        let t = try store.loadTaxonomy(runID: runID)
        #expect(t != nil)
        #expect(t!.folders.count == 2)
        #expect(t!.folders[0].name == "News")
        #expect(t!.folders[0].rationale == "")
    }

    @Test("loadTaxonomy returns nil for non-existent run")
    func loadTaxonomyMissing() throws {
        let store = try makeStore()
        let t = try store.loadTaxonomy(runID: 9999)
        #expect(t == nil)
    }

    @Test("setEnrichment and getEnrichment round-trips")
    func enrichmentRoundTrip() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        try store.upsert([Bookmark(id: "a", title: "X", url: "https://x.com")], runID: runID)

        let enrichment = Enrichment(
            bookmarkID: "a",
            metaDescription: "A test description",
            isDeadLink: false,
            httpStatus: 200
        )
        try store.setEnrichment(enrichment)

        let loaded = try store.getEnrichment(bookmarkID: "a")
        #expect(loaded != nil)
        #expect(loaded?.metaDescription == "A test description")
        #expect(loaded?.isDeadLink == false)
        #expect(loaded?.httpStatus == 200)
    }

    @Test("getEnrichment returns nil for missing bookmark")
    func enrichmentMissing() throws {
        let store = try makeStore()
        let result = try store.getEnrichment(bookmarkID: "nonexistent")
        #expect(result == nil)
    }

    @Test("getEnrichments batch fetches multiple enrichments")
    func enrichmentsBatchFetch() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        try store.upsert([
            Bookmark(id: "a", title: "X", url: "https://x.com"),
            Bookmark(id: "b", title: "Y", url: "https://y.com"),
            Bookmark(id: "c", title: "Z", url: "https://z.com"),
        ], runID: runID)

        try store.setEnrichment(Enrichment(bookmarkID: "a", metaDescription: "Desc A"))
        try store.setEnrichment(Enrichment(bookmarkID: "b", metaDescription: "Desc B", isDeadLink: true))

        let results = try store.getEnrichments(bookmarkIDs: ["a", "b", "c"])
        #expect(results.count == 2)
        #expect(results["a"]?.metaDescription == "Desc A")
        #expect(results["b"]?.isDeadLink == true)
        #expect(results["c"] == nil)
    }

    @Test("clearEnrichments removes all enrichments")
    func clearEnrichments() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        try store.upsert([Bookmark(id: "a", title: "X", url: "https://x.com")], runID: runID)

        try store.setEnrichment(Enrichment(bookmarkID: "a", metaDescription: "Test"))
        try store.clearEnrichments()

        let loaded = try store.getEnrichment(bookmarkID: "a")
        #expect(loaded == nil)
    }

    @Test("setEnrichment overwrites existing entry")
    func enrichmentOverwrite() throws {
        let store = try makeStore()
        let runID = try store.createRun(sourcePath: "test.html")
        try store.upsert([Bookmark(id: "a", title: "X", url: "https://x.com")], runID: runID)

        try store.setEnrichment(Enrichment(bookmarkID: "a", metaDescription: "Old desc"))
        try store.setEnrichment(Enrichment(bookmarkID: "a", metaDescription: "New desc", isDeadLink: true))

        let loaded = try store.getEnrichment(bookmarkID: "a")
        #expect(loaded?.metaDescription == "New desc")
        #expect(loaded?.isDeadLink == true)
    }
}
