import Testing
import Foundation
import LazyBookmarksKit
@testable import EvalKit

@Suite("LabelStore")
struct LabelStoreTests {

    @Test("upsert and fetch round-trip")
    func roundTrip() throws {
        let store = try LabelStore(path: ":memory:")
        let labels = [
            Label(bookmarkID: "a", folder: "News", verdict: .accept, source: "human"),
            Label(bookmarkID: "b", folder: "Cooking", verdict: .reject, source: "human", note: "wrong topic"),
        ]
        try store.upsert(labels)
        let fetched = try store.allLabels()
        #expect(fetched.count == 2)
        #expect(fetched[0].bookmarkID == "a")
        #expect(fetched[0].verdict == .accept)
        #expect(fetched[1].note == "wrong topic")
    }

    @Test("labelsByKey returns correct mapping")
    func byKey() throws {
        let store = try LabelStore(path: ":memory:")
        try store.upsert([
            Label(bookmarkID: "a", folder: "News", verdict: .accept),
            Label(bookmarkID: "a", folder: "Cooking", verdict: .reject),
        ])
        let byKey = try store.labelsByKey()
        #expect(byKey.count == 2)
        #expect(byKey[LabelKey(bookmarkID: "a", folder: "News")]?.verdict == .accept)
        #expect(byKey[LabelKey(bookmarkID: "a", folder: "Cooking")]?.verdict == .reject)
    }

    @Test("upsert replaces existing key")
    func upsertReplaces() throws {
        let store = try LabelStore(path: ":memory:")
        try store.upsert([Label(bookmarkID: "a", folder: "News", verdict: .reject)])
        try store.upsert([Label(bookmarkID: "a", folder: "News", verdict: .accept)])
        let byKey = try store.labelsByKey()
        #expect(byKey.count == 1)
        #expect(byKey[LabelKey(bookmarkID: "a", folder: "News")]?.verdict == .accept)
    }

    @Test("importCSV parses valid rows")
    func importCSV() throws {
        let store = try LabelStore(path: ":memory:")
        let csv = """
        bookmark_id,folder,verdict,source,note
        a,News,accept,human,
        b,Cooking,reject,judge,bad fit
        c,News,,human,
        """
        let count = try store.importCSV(Data(csv.utf8))
        #expect(count == 2)
        let byKey = try store.labelsByKey()
        #expect(byKey[LabelKey(bookmarkID: "a", folder: "News")]?.verdict == .accept)
        #expect(byKey[LabelKey(bookmarkID: "b", folder: "Cooking")]?.verdict == .reject)
    }

    @Test("importCSV skips rows with empty verdict")
    func importCSVSkipEmpty() throws {
        let store = try LabelStore(path: ":memory:")
        let csv = """
        bookmark_id,folder,verdict,source,note
        a,News,,human,
        b,Cooking,accept,human,
        """
        let count = try store.importCSV(Data(csv.utf8))
        #expect(count == 1)
    }

    @Test("exportCSV produces valid output")
    func exportCSV() throws {
        let store = try LabelStore(path: ":memory:")
        try store.upsert([
            Label(bookmarkID: "a", folder: "News", verdict: .accept, source: "human"),
        ])
        let data = try store.exportCSV()
        let csv = String(data: data, encoding: .utf8)!
        #expect(csv.contains("bookmark_id,folder,verdict,source,note"))
        #expect(csv.contains("a,News,accept,human"))
    }
}

@Suite("Sampler")
struct SamplerTests {

    @Test("stratified sample returns up to n rows")
    func sampleSize() {
        let decisions = (0..<100).map { i in
            LazyBookmarksKit.Classifier.Decision(
                bookmarkID: "b\(i)",
                folder: i % 3 == 0 ? "A" : (i % 3 == 1 ? "B" : "C"),
                confidence: i
            )
        }
        let bookmarks = (0..<100).map { i in
            LazyBookmarksKit.Bookmark(id: "b\(i)", title: "Title \(i)", url: "https://example.com/\(i)")
        }
        let rows = Sampler.stratifiedSample(decisions: decisions, bookmarks: bookmarks, n: 30, seed: 42)
        #expect(rows.count <= 30)
        #expect(rows.count > 0)
    }

    @Test("toCSV includes header and all fields")
    func toCSVFormat() {
        let rows = [
            Sampler.SampleRow(bookmarkID: "x", title: "Hello", url: "https://example.com", domain: "example.com", assignedFolder: "News", confidence: 80),
        ]
        let csv = Sampler.toCSV(rows)
        #expect(csv.contains("bookmark_id,title,url,domain,assigned_folder,confidence,verdict,note"))
        #expect(csv.contains("x,Hello,https://example.com,example.com,News,80,,"))
    }

    @Test("empty decisions returns empty sample")
    func emptyDecisions() {
        let rows = Sampler.stratifiedSample(decisions: [], bookmarks: [], n: 10, seed: 42)
        #expect(rows.isEmpty)
    }
}
