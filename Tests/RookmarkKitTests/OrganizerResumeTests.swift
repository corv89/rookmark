import Foundation
import SQLite3
import Testing
@testable import RookmarkKit

// No-model tests for `organize --stateful`: per-batch commit, resume, and
// resumed/fresh output parity. The on-device model is bypassed through the
// Organizer's internal `makeClassifier` seam; everything else (pinned
// taxonomy, clustering off, enrichment off) keeps the run off the network
// and off TaxonomyBuilder, so these are deterministic store/pipeline tests.

/// Deterministic stand-in for `Classifier`: records what it was asked to
/// classify, derives decisions from the bookmark title, and streams them
/// through `onBatch` in fixed-width slices — the same observable shape the
/// real classifier has. `failAfterBatches` simulates a SIGINT: after that
/// many batches have landed (and been committed by the organizer's
/// per-batch handler), the next model call throws `CancellationError`.
private actor SpyClassifier: Classification {
    let batchWidth: Int
    let failAfterBatches: Int?
    let onEmit: (@Sendable ([Classifier.Decision]) -> Void)?

    private(set) var calls: [[Bookmark]] = []
    private(set) var seenTaxonomies: [Taxonomy] = []
    private(set) var emittedBatches: [[Classifier.Decision]] = []
    private var batchesEmitted = 0

    init(
        batchWidth: Int,
        failAfterBatches: Int? = nil,
        onEmit: (@Sendable ([Classifier.Decision]) -> Void)? = nil
    ) {
        self.batchWidth = batchWidth
        self.failAfterBatches = failAfterBatches
        self.onEmit = onEmit
    }

    func classify(
        _ bookmarks: [Bookmark],
        taxonomy: Taxonomy,
        enrichments: [String: ContentEnricher.EnrichResult]?,
        progress: Classifier.ProgressHandler?,
        onBatch: Classifier.BatchHandler?
    ) async throws -> [Classifier.Decision] {
        calls.append(bookmarks)
        seenTaxonomies.append(taxonomy)
        var all: [Classifier.Decision] = []
        var index = 0
        while index < bookmarks.count {
            if let failAfterBatches, batchesEmitted >= failAfterBatches {
                throw CancellationError()   // earlier batches already landed
            }
            let end = min(index + batchWidth, bookmarks.count)
            let batch = bookmarks[index..<end].map(Self.decision(for:))
            batchesEmitted += 1
            all.append(contentsOf: batch)
            emittedBatches.append(batch)
            onBatch?(batch)
            progress?(all.count, bookmarks.count)
            onEmit?(batch)
            index = end
        }
        return all
    }

    /// "News …" → News/80, "Dev …" → Dev/80, everything else → Unsorted/5
    /// (below the default confidence floor of 15, exercising the floor path).
    static func decision(for b: Bookmark) -> Classifier.Decision {
        if b.title.hasPrefix("News") {
            return Classifier.Decision(bookmarkID: b.id, folder: "News", confidence: 80)
        }
        if b.title.hasPrefix("Dev") {
            return Classifier.Decision(bookmarkID: b.id, folder: "Dev", confidence: 80)
        }
        return Classifier.Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: 5)
    }
}

/// Thread-safe box for values captured inside `@Sendable` handler closures.
private final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }
    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "rookmark_resume_\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// SQLITE_TRANSIENT is a C macro; the standard Swift bit-cast stand-in.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Seeds `runs.taxonomy_json` on a still-'running' run. Store's public API
/// writes taxonomy only via finishRun (which completes the run), so the
/// resume-with-stored-taxonomy path is exercised by writing the column
/// directly — the state a run-start persist will produce (M11.3).
private func seedStoredTaxonomy(_ taxonomy: Taxonomy, runID: Int64, dbPath: String) throws {
    let json = String(
        data: try JSONEncoder().encode(TaxonomyEnvelope(v: 2, folders: taxonomy.folders)),
        encoding: .utf8)!
    var db: OpaquePointer?
    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
        throw NSError(domain: "seedStoredTaxonomy", code: 1)
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }   // finalize(nil) is a no-op
    guard sqlite3_prepare_v2(db, "UPDATE runs SET taxonomy_json = ?1 WHERE id = ?2", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_bind_text(stmt, 1, json, -1, sqliteTransient) == SQLITE_OK,
          sqlite3_bind_int64(stmt, 2, runID) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_DONE
    else { throw NSError(domain: "seedStoredTaxonomy", code: 2) }
}

private func fixtureHTML() -> String {
    NetscapeBookmarkWriter().write([
        Bookmark(id: "", title: "Dev Alpha", url: "https://dev-alpha.example.com/2024/prototype"),
        Bookmark(id: "", title: "Dev Beta", url: "https://dev-beta.example.org/release-notes"),
        Bookmark(id: "", title: "Meh Gamma", url: "https://meh-gamma.example.net/page"),
        Bookmark(id: "", title: "News Alpha", url: "https://news-alpha.example.com/brief"),
        Bookmark(id: "", title: "News Beta", url: "https://news-beta.example.org/coverage"),
    ])
}

/// The fixture as `organize` sees it: parsed back and id-sorted (the
/// determinism anchor at the top of `organize`).
private func sortedFixtureBookmarks(html: String) -> [Bookmark] {
    var bookmarks = NetscapeBookmarkParser().parse(html).bookmarks
    bookmarks.sort { $0.id < $1.id }
    return bookmarks
}

private func makeOptions(storePath: String?, sourcePath: String) -> Organizer.Options {
    Organizer.Options(
        stateful: storePath != nil,
        storePath: storePath,
        sourcePath: sourcePath,
        clustering: ClusteringConfig(enabled: false),
        pinnedTaxonomy: Taxonomy(folders: [
            .init(name: "News", rationale: "Current events"),
            .init(name: "Dev", rationale: "Software development"),
        ]),
        enrich: false
    )
}

private func makeOrganizer(_ spy: SpyClassifier) -> Organizer {
    Organizer(factory: SessionFactory(), makeClassifier: { _, _, _ in spy })
}

@Suite("Organizer resume (no-model)")
struct OrganizerResumeTests {

    @Test("per-batch commit: decisions land in the store before classify() returns")
    func perBatchCommit() async throws {
        guard case .available = SessionFactory().availability() else { return }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sourcePath = dir + "input.html"
        let storePath = dir + "input.db"
        let html = fixtureHTML()
        let fixture = sortedFixtureBookmarks(html: html)
        #expect(fixture.count == 5)

        // Second handle on the same SQLite file, read mid-run through the
        // public API. commit sets assigned_folder + committed=1 together and
        // upsert inserts both nil, so `assignedFolder != nil` ⟺ committed.
        let probe = try Store(path: storePath)
        let runIDs = Collector<Int64>()
        let committedCounts = Collector<Int>()
        let spy = SpyClassifier(batchWidth: 2, onEmit: { _ in
            if let rid = try? probe.latestUnfinishedRun(sourcePath: sourcePath) {
                runIDs.append(rid)
                if let rows = try? probe.all(runID: rid) {
                    committedCounts.append(rows.filter { $0.assignedFolder != nil }.count)
                }
            }
        })

        let result = try await makeOrganizer(spy).organize(
            html: html, options: makeOptions(storePath: storePath, sourcePath: sourcePath))

        // After the k-th batch, exactly k×2 decisions were already durable.
        // The probe fired inside the classification loop, so this proves the
        // commits happened before classify() returned.
        #expect(committedCounts.all == [2, 4, 5])
        #expect(runIDs.all.count == 3)

        // Run finished exactly once and is no longer the resume target.
        let rid = try #require(runIDs.all.first)
        let unfinished = try probe.latestUnfinishedRun(sourcePath: sourcePath)
        #expect(unfinished == nil)
        let taxonomy = try probe.loadTaxonomy(runID: rid)
        #expect(taxonomy != nil)

        // Every row committed with the spy's folder/confidence.
        let rows = try probe.all(runID: rid)
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { $0.assignedFolder != nil })
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for b in fixture {
            let expected = SpyClassifier.decision(for: b)
            #expect(byID[b.id]?.assignedFolder == expected.folder)
            #expect(byID[b.id]?.confidence == expected.confidence)
        }

        #expect(result.bookmarks.count == 5)
        #expect(result.bookmarks.allSatisfy { $0.assignedFolder != nil })
    }

    @Test("resume skips committed bookmarks and reuses the interrupted run")
    func resumeSkipsCommitted() async throws {
        guard case .available = SessionFactory().availability() else { return }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sourcePath = dir + "input.html"
        let storePath = dir + "input.db"
        let html = fixtureHTML()
        let fixture = sortedFixtureBookmarks(html: html)
        let opts = makeOptions(storePath: storePath, sourcePath: sourcePath)

        // First attempt: die after one batch (2 of 5) landed and committed.
        let firstSpy = SpyClassifier(batchWidth: 2, failAfterBatches: 1)
        await #expect(throws: CancellationError.self) {
            try await makeOrganizer(firstSpy).organize(html: html, options: opts)
        }

        let store = try Store(path: storePath)
        let rid = try #require(try store.latestUnfinishedRun(sourcePath: sourcePath))
        let committed = try store.all(runID: rid).filter { $0.assignedFolder != nil }
        #expect(committed.count == 2)
        let pending = try store.uncommitted(runID: rid)
        #expect(pending.count == 3)

        // Resume: only the uncommitted subset reaches the classifier.
        let resumeSpy = SpyClassifier(batchWidth: 2)
        let resumeInfo = Collector<(Int, Int)>()
        _ = try await makeOrganizer(resumeSpy).organize(
            html: html, options: opts,
            onResume: { already, total in resumeInfo.append((already, total)) })

        // Asked to classify exactly the pending subset, in parse (id-sorted)
        // order — never the two bookmarks whose decisions were already stored.
        let calls = await resumeSpy.calls
        #expect(calls.count == 1)
        let asked = try #require(calls.first)
        #expect(asked.map(\.id) == Array(fixture.dropFirst(2).map(\.id)))

        // The resume line: 2 of 5 already classified.
        #expect(resumeInfo.all.count == 1)
        let info = try #require(resumeInfo.all.first)
        #expect(info.0 == 2)
        #expect(info.1 == 5)

        // Run reused (no duplicate): the same rid is now finished, no
        // 'running' run remains, and finishRun wrote its taxonomy.
        let unfinished = try store.latestUnfinishedRun(sourcePath: sourcePath)
        #expect(unfinished == nil)
        let taxonomy = try store.loadTaxonomy(runID: rid)
        #expect(taxonomy != nil)
        let finalRows = try store.all(runID: rid)
        #expect(finalRows.count == 5)
        #expect(finalRows.allSatisfy { $0.assignedFolder != nil })
    }

    @Test("resume reuses the interrupted run's stored taxonomy")
    func resumeReusesStoredTaxonomy() async throws {
        guard case .available = SessionFactory().availability() else { return }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sourcePath = dir + "input.html"
        let storePath = dir + "input.db"
        let html = fixtureHTML()

        // Leg 1: die after one batch (2 of 5) landed and committed — pinned
        // taxonomy keeps this leg off TaxonomyBuilder, exactly like the
        // resumeSkipsCommitted setup.
        let opts = makeOptions(storePath: storePath, sourcePath: sourcePath)
        let firstSpy = SpyClassifier(batchWidth: 2, failAfterBatches: 1)
        await #expect(throws: CancellationError.self) {
            try await makeOrganizer(firstSpy).organize(html: html, options: opts)
        }

        let store = try Store(path: storePath)
        let rid = try #require(try store.latestUnfinishedRun(sourcePath: sourcePath))
        let committed = try store.all(runID: rid).filter { $0.assignedFolder != nil }
        #expect(committed.count == 2)

        // Pretend the interrupted run persisted its own vocabulary (M11.3
        // run-start persist): folder names deliberately ≠ the pinned News/Dev,
        // so the assertion below is unambiguous.
        let stored = Taxonomy(folders: [
            .init(name: "Stored News", rationale: "Prior run folder"),
            .init(name: "Stored Dev", rationale: "Prior run folder"),
        ])
        try seedStoredTaxonomy(stored, runID: rid, dbPath: storePath)
        #expect(try store.loadTaxonomy(runID: rid) == stored)   // seeding sanity via public API

        // Leg 2: resume with no pinned taxonomy — the stored one must reach
        // the classifier, and TaxonomyBuilder must never run (a fresh build
        // would need the real model for this flat fixture).
        var resumeOpts = makeOptions(storePath: storePath, sourcePath: sourcePath)
        resumeOpts.pinnedTaxonomy = nil
        let resumeSpy = SpyClassifier(batchWidth: 2)
        let result = try await makeOrganizer(resumeSpy).organize(html: html, options: resumeOpts)

        let taxonomies = await resumeSpy.seenTaxonomies
        #expect(taxonomies.count == 1)          // one classify call for the 3 pending
        #expect(taxonomies.first == stored)     // the stored taxonomy, not a fresh build
        #expect(result.taxonomy == stored)

        // Run finished against the same vocabulary it resumed with.
        #expect(try store.latestUnfinishedRun(sourcePath: sourcePath) == nil)
        #expect(try store.loadTaxonomy(runID: rid) == stored)   // finishRun re-persisted it (cap is a no-op here)
    }

    @Test("pinned taxonomy still wins over the stored one on resume")
    func pinnedWinsOverStoredOnResume() async throws {
        guard case .available = SessionFactory().availability() else { return }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sourcePath = dir + "input.html"
        let storePath = dir + "input.db"
        let html = fixtureHTML()

        // Same interrupted-run setup, including the seeded stored taxonomy.
        let opts = makeOptions(storePath: storePath, sourcePath: sourcePath)
        let firstSpy = SpyClassifier(batchWidth: 2, failAfterBatches: 1)
        await #expect(throws: CancellationError.self) {
            try await makeOrganizer(firstSpy).organize(html: html, options: opts)
        }

        let store = try Store(path: storePath)
        let rid = try #require(try store.latestUnfinishedRun(sourcePath: sourcePath))
        let committed = try store.all(runID: rid).filter { $0.assignedFolder != nil }
        #expect(committed.count == 2)

        let stored = Taxonomy(folders: [
            .init(name: "Stored News", rationale: "Prior run folder"),
            .init(name: "Stored Dev", rationale: "Prior run folder"),
        ])
        try seedStoredTaxonomy(stored, runID: rid, dbPath: storePath)
        #expect(try store.loadTaxonomy(runID: rid) == stored)

        // Resume WITH a pinned taxonomy: the pin must override the stored one —
        // a user-supplied taxonomy always wins.
        var resumeOpts = makeOptions(storePath: storePath, sourcePath: sourcePath)
        resumeOpts.pinnedTaxonomy = Taxonomy(folders: [.init(name: "Pinned Only", rationale: "User supplied")])
        let resumeSpy = SpyClassifier(batchWidth: 2)
        let result = try await makeOrganizer(resumeSpy).organize(html: html, options: resumeOpts)

        let taxonomies = await resumeSpy.seenTaxonomies
        #expect(taxonomies.count == 1)
        #expect(taxonomies.first == resumeOpts.pinnedTaxonomy)
        #expect(taxonomies.first != stored)     // disjoint names: no accidental equality
        #expect(result.taxonomy == resumeOpts.pinnedTaxonomy)
    }

    @Test("resumed output matches an uninterrupted run")
    func resumedOutputMatchesFresh() async throws {
        guard case .available = SessionFactory().availability() else { return }

        let dirA = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dirA) }
        let dirB = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dirB) }
        let html = fixtureHTML()
        let fixture = sortedFixtureBookmarks(html: html)

        // A: one uninterrupted stateful run.
        let sourceA = dirA + "input.html"
        let storePathA = dirA + "input.db"
        let probeA = try Store(path: storePathA)
        let runIDsA = Collector<Int64>()
        let spyA = SpyClassifier(batchWidth: 2, onEmit: { _ in
            if let rid = try? probeA.latestUnfinishedRun(sourcePath: sourceA) {
                runIDsA.append(rid)
            }
        })
        let resultA = try await makeOrganizer(spyA).organize(
            html: html, options: makeOptions(storePath: storePathA, sourcePath: sourceA))

        // B: interrupted after the first batch, then resumed with a fresh spy.
        let sourceB = dirB + "input.html"
        let storePathB = dirB + "input.db"
        let optsB = makeOptions(storePath: storePathB, sourcePath: sourceB)
        let probeB = try Store(path: storePathB)
        let runIDsB = Collector<Int64>()
        let runIDProbe: @Sendable ([Classifier.Decision]) -> Void = { _ in
            if let rid = try? probeB.latestUnfinishedRun(sourcePath: sourceB) {
                runIDsB.append(rid)
            }
        }
        let spyB1 = SpyClassifier(batchWidth: 2, failAfterBatches: 1, onEmit: runIDProbe)
        await #expect(throws: CancellationError.self) {
            try await makeOrganizer(spyB1).organize(html: html, options: optsB)
        }
        let spyB2 = SpyClassifier(batchWidth: 2, onEmit: runIDProbe)
        let resultB = try await makeOrganizer(spyB2).organize(html: html, options: optsB)

        // The interrupted and resumed legs worked the same run.
        let runIDs = runIDsB.all
        #expect(!runIDs.isEmpty)
        #expect(Set(runIDs).count == 1)

        // Same placements, same order, same explanations, same breakdown —
        // including the conf-5 Unsorted item through the floor path.
        #expect(resultA.bookmarks == resultB.bookmarks)
        #expect(resultA.decisions == resultB.decisions)
        #expect(resultA.taxonomy == resultB.taxonomy)
        #expect(resultA.unsortedCauses == resultB.unsortedCauses)
        #expect(resultA.unsortedCauses.belowFloor == 1)
        #expect(resultA.bookmarks.count == fixture.count)

        // The stores agree on folder + confidence per id, too.
        let ridA = try #require(runIDsA.all.first)
        let ridB = try #require(runIDs.first)
        let rowsA = try probeA.all(runID: ridA)
        let rowsB = try probeB.all(runID: ridB)
        #expect(rowsA.count == fixture.count)
        #expect(rowsB.count == fixture.count)
        let byIDA = Dictionary(uniqueKeysWithValues: rowsA.map { ($0.id, $0) })
        let byIDB = Dictionary(uniqueKeysWithValues: rowsB.map { ($0.id, $0) })
        for b in fixture {
            #expect(byIDA[b.id]?.assignedFolder == byIDB[b.id]?.assignedFolder)
            #expect(byIDA[b.id]?.confidence == byIDB[b.id]?.confidence)
        }
    }

    @Test("stateless run: onBatch forwarded unmodified, no store created")
    func statelessIsolation() async throws {
        guard case .available = SessionFactory().availability() else { return }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sourcePath = dir + "input.html"
        let html = fixtureHTML()
        let fixture = sortedFixtureBookmarks(html: html)

        let spy = SpyClassifier(batchWidth: 2)
        let forwarded = Collector<[Classifier.Decision]>()
        let result = try await makeOrganizer(spy).organize(
            html: html,
            options: makeOptions(storePath: nil, sourcePath: sourcePath),
            onBatch: { forwarded.append($0) })

        // Full, id-sorted input, exactly once.
        let calls = await spy.calls
        #expect(calls.count == 1)
        let asked = try #require(calls.first)
        #expect(asked.map(\.id) == fixture.map(\.id))

        // Every emitted batch reached the caller untouched, same order: the
        // stateless path hands through the identical closure, zero new work.
        let emitted = await spy.emittedBatches
        #expect(!emitted.isEmpty)
        #expect(forwarded.all == emitted)

        // No store anywhere: stateful=false must not create the derived .db.
        #expect(!FileManager.default.fileExists(atPath: sourcePath + ".db"))
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(dirContents.isEmpty)

        #expect(result.bookmarks.count == fixture.count)
        #expect(result.bookmarks.allSatisfy { $0.assignedFolder != nil })
    }
}
