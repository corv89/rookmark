import Foundation
import RookmarkKit
import Testing

@testable import RookmarkApp

@Suite("Import source selection")
@MainActor
struct ImportSourceTests {
    private let export = URL(filePath: "/Users/rook/Downloads/bookmarks_2026.html")
    private let other  = URL(filePath: "/Users/rook/Downloads/chrome.html")

    @Test("the profile and a dropped file are each named for what they are")
    func naming() {
        #expect(OrganizerModel.Source.orionProfile.name == "Orion profile")
        #expect(OrganizerModel.Source.file(export).name == "bookmarks_2026.html")
    }

    @Test("html and htm are importable, anything else is not")
    func importable() {
        let dir = URL(filePath: "/tmp/exports")
        #expect(OrganizerModel.isImportableFile(dir.appending(path: "b.html")))
        #expect(OrganizerModel.isImportableFile(dir.appending(path: "B.HTML")))
        #expect(OrganizerModel.isImportableFile(dir.appending(path: "b.htm")))
        #expect(!OrganizerModel.isImportableFile(dir.appending(path: "b.json")))
        #expect(!OrganizerModel.isImportableFile(dir.appending(path: "b.html.db")))
        #expect(!OrganizerModel.isImportableFile(dir.appending(path: "report.pdf")))
        // A directory with no extension must not pass either: folders are the
        // most likely thing a drag actually carries.
        #expect(!OrganizerModel.isImportableFile(URL(filePath: "/tmp/exports")))
    }

    @Test("a non-export is refused with a message that names the file")
    func refusesNonExport() throws {
        let model = OrganizerModel()
        model.requestImport(from: URL(filePath: "/tmp/exports/bookmarks.json"))
        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message.contains("bookmarks.json"))
        #expect(model.pendingImport == nil)
    }

    @Test("a run on screen makes the next import a confirmed replacement")
    func confirmedReplacement() {
        let model = OrganizerModel()
        model.updateRows([.init(id: "a", title: "A", url: "https://a.example",
                                folder: "Development", confidence: 90, modelChoice: nil)])
        #expect(model.importRequiresConfirmation(for: export))

        model.requestImport(from: export)
        #expect(model.pendingImport == export, "gated, not loaded")
        #expect(model.source == nil && model.allBookmarks.isEmpty, "nothing was read yet")

        model.cancelImport()
        #expect(model.pendingImport == nil)
    }

    @Test("nothing on screen needs no confirmation")
    func freshImport() {
        let model = OrganizerModel()
        #expect(!model.importRequiresConfirmation(for: export))
    }

    @Test("re-importing the file the run came from is a reopen, not a replacement")
    func sameFileReopens() {
        let model = OrganizerModel()
        model.updateSource(.file(export))
        model.updateRows([.init(id: "a", title: "A", url: "https://a.example",
                                folder: "Development", confidence: 90, modelChoice: nil)])
        #expect(!model.importRequiresConfirmation(for: export))
        #expect(model.importRequiresConfirmation(for: other))
    }

    // MARK: loading, through the real parser

    private func writeExport(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-import-\(UUID().uuidString).html")
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a dropped export loads through the same parser the CLI uses")
    func loadsExport() async throws {
        let url = try writeExport("""
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><H3>Dev</H3>
            <DL><p>
                <DT><A HREF="https://rookmark-import-test.invalid/">Swift</A>
                <DT><A HREF="https://rookmark-import-test.invalid/b">Example</A>
            </DL><p>
        </DL><p>
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        // Ids derive from the normalized URL, so a fixture on a real host
        // (swift.org) can collide with a bookmark in the host machine's own
        // session snapshot, which restoreSession would then pull into the test
        // model and break `rows.isEmpty`. `.invalid` is RFC 2606 reserved and
        // can never collide.
        let model = OrganizerModel()
        await model.importFile(at: url, discardingSession: false)

        #expect(model.phase == .idle)
        #expect(model.source == .file(url))
        #expect(model.sourceSummary?.bookmarkCount == 2)
        #expect(model.allBookmarks.count == 2)
        #expect(model.sourceSummary?.orphanedFolderReferences == nil)
        // Synthetic ids cannot appear in a real session snapshot, so nothing
        // is restored. (A host session may still set `staleness`; not asserted.)
        #expect(model.rows.isEmpty)
    }

    @Test("an export with no bookmarks fails with a message naming the file")
    func emptyExport() async throws {
        let url = try writeExport("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n</DL><p>\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let model = OrganizerModel()
        await model.importFile(at: url, discardingSession: false)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message.contains(url.lastPathComponent))
        // The failure path must leave the model honestly empty: a stale library
        // under the new source's name would re-arm Organize (T3 review, major 1).
        #expect(model.allBookmarks.isEmpty)
        #expect(model.remaining.isEmpty)   // Organize stays gated; nothing is armed
    }

    @Test("a failed import over a run on screen rolls the model back and keeps the run")
    func failedImportRollsBack() async throws {
        let good = try writeExport("""
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://rookmark-import-test.invalid/a">A</A>
            <DT><A HREF="https://rookmark-import-test.invalid/b">B</A>
        </DL><p>
        """)
        let bad = try writeExport("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n</DL><p>\n")
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }

        let model = OrganizerModel()
        await model.importFile(at: good, discardingSession: false)
        #expect(model.phase == .idle && model.allBookmarks.count == 2)

        // A run on screen, exactly what restoreSession would have produced.
        let bookmark = model.allBookmarks[0]
        model.updateRows([.init(id: bookmark.id, title: "A", url: bookmark.url,
                                folder: "Development", confidence: 90, modelChoice: nil)])
        let phaseBefore = model.phase

        await model.importFile(at: bad, discardingSession: false)

        #expect(model.phase == phaseBefore, "a failed import does not flip the phase")
        #expect(model.source == .file(good), "source rolls back to the library on screen")
        #expect(model.allBookmarks.count == 2, "the old library is back, not left armed under the new name")
        #expect(model.rows.map(\.id) == [bookmark.id], "the review table survives")
        #expect(model.importFailureMessage?.contains(bad.lastPathComponent) == true)
        model.dismissImportFailure()
        #expect(model.importFailureMessage == nil)
    }

    @Test("a refused import with a run on screen reports instead of taking over the view")
    func refusedImportKeepsRun() {
        let model = OrganizerModel()
        model.updateSource(.file(export))
        model.updateRows([.init(id: "a", title: "A", url: "https://a.example",
                                folder: "Development", confidence: 90, modelChoice: nil)])
        model.requestImport(from: URL(filePath: "/tmp/exports/bookmarks.json"))
        guard case .idle = model.phase else {
            Issue.record("expected .idle, got \(model.phase)")
            return
        }
        #expect(model.importFailureMessage?.contains("bookmarks.json") == true)
        #expect(model.rows.count == 1 && model.source == .file(export))
    }
}

/// The way back to the welcome screen. Distinct from `discardSession()`, which
/// keeps the source loaded so Organize can run again over the same library:
/// this one unloads the library too, which is the only thing that puts the
/// browser picker back on screen.
///
/// Every model here is built with `persistingSessions: false` for the reason
/// the seam exists — `startFresh()` routes through `discardSession()`, which
/// clears the session store, and `swift test` runs on the developer's own Mac
/// where that file holds a live review session.
@Suite("Start fresh")
@MainActor
struct StartFreshTests {
    private let export = URL(filePath: "/Users/rook/Downloads/bookmarks_2026.html")

    private func loaded() -> OrganizerModel {
        let model = OrganizerModel(persistingSessions: false)
        model.updateSource(.file(export))
        model.updateRows([
            .init(id: "a", title: "A", url: "https://a.example",
                  folder: "Development", confidence: 90, modelChoice: nil),
        ])
        return model
    }

    @Test("start fresh unloads the source, not just the run")
    func clearsSourceAndLibrary() async throws {
        let model = OrganizerModel(persistingSessions: false)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-startfresh-\(UUID().uuidString).html")
        try """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://rookmark-startfresh-test.invalid/a">A</A>
        </DL><p>
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        await model.importFile(at: url, discardingSession: false)
        #expect(model.source == .file(url))
        #expect(model.sourceSummary?.bookmarkCount == 1)
        #expect(!model.allBookmarks.isEmpty)

        model.startFresh()

        // All three are what the welcome screen keys off: ContentView shows the
        // browser grid on `.idle` with a nil source, and the sidebar's summary
        // section disappears with sourceSummary.
        #expect(model.source == nil)
        #expect(model.allBookmarks.isEmpty)
        #expect(model.sourceSummary == nil)
        #expect(model.phase == .idle)
        // Organize must not stay armed against a library that is no longer loaded.
        #expect(model.remaining.isEmpty)
    }

    @Test("start fresh does everything discard does")
    func sharesDiscardsWork() {
        let model = loaded()
        model.updateWorkingTaxonomy([.init(name: "Only Folder", rationale: "")])
        model.selectedRowID = "a"
        model.selectedFolder = "Development"

        model.startFresh()

        #expect(model.rows.isEmpty)
        // Not empty: resetTaxonomyToPinned recounts, so the group list comes
        // back as the pinned folders at zero. Nothing is filed anywhere, which
        // is the part that matters — and the sidebar only draws this section
        // when there are rows.
        #expect(model.folders.allSatisfy { $0.count == 0 })
        #expect(model.newFolders.isEmpty)
        #expect(model.staleness == nil)
        #expect(model.selectedRowID == nil)
        #expect(model.selectedFolder == OrganizerModel.allFolders)
        #expect(model.importFailureMessage == nil)
        // Folder edits are undone with the run, exactly as Discard undoes them.
        #expect(model.workingFolders.count > 1)
        #expect(!model.workingFolders.contains { $0.name == "Only Folder" })
    }

    @Test("a run on screen is thrown away only after confirmation")
    func confirmsWhenThereIsWorkToLose() {
        let model = loaded()

        model.requestStartFresh()
        #expect(model.pendingStartFresh, "gated, not cleared")
        #expect(model.source == .file(export), "nothing happened yet")
        #expect(model.rows.count == 1)

        model.cancelStartFresh()
        #expect(!model.pendingStartFresh)
        #expect(model.source == .file(export) && model.rows.count == 1)

        model.requestStartFresh()
        model.confirmStartFresh()
        #expect(!model.pendingStartFresh)
        #expect(model.source == nil && model.rows.isEmpty)
    }

    @Test("confirming without a pending request does nothing")
    func confirmNeedsARequest() {
        let model = loaded()
        model.confirmStartFresh()
        #expect(model.source == .file(export) && model.rows.count == 1)
    }

    @Test("nothing to lose, no dialog")
    func noRowsSkipsTheDialog() {
        let model = OrganizerModel(persistingSessions: false)
        model.updateSource(.file(export))
        model.requestStartFresh()
        #expect(!model.pendingStartFresh)
        #expect(model.source == nil)
    }

    @Test("a running classification is never cleared out from under itself")
    func refusedWhileBusy() async {
        let model = loaded()
        await model.updatePhase(.classifying(done: 1, total: 10))
        model.requestStartFresh()
        #expect(!model.pendingStartFresh)
        #expect(model.source == .file(export) && model.rows.count == 1)
    }
}
