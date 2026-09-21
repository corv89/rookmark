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

    @Test("every live profile is named for its browser")
    func liveProfileNaming() {
        let path = URL(filePath: "/tmp/profile")
        #expect(OrganizerModel.Source.liveProfile(.chrome, path).name == "Chrome profile")
        #expect(OrganizerModel.Source.liveProfile(.firefox, path).name == "Firefox profile")
        // Every case is named: an unnamed browser would show as a blank library
        // in the sidebar, which is the one thing Source.name exists to prevent.
        for browser in OrganizerModel.LiveBrowser.allCases {
            #expect(OrganizerModel.Source.liveProfile(browser, path).name == "\(browser.name) profile")
        }
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

    // MARK: live browser profiles, through the real importers

    /// A Chromium `Bookmarks` file, which is what `.liveProfile(.chrome, _)`
    /// dispatches to. `.invalid` hosts for the same reason the export fixtures
    /// use them: ids come from the URL, so a real host can collide with the
    /// host machine's own session snapshot.
    private func writeChromiumProfile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-chromium-\(UUID().uuidString).json")
        try """
        {"version":1,"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
            {"type":"url","name":"A","url":"https://rookmark-live-test.invalid/a"},
            {"type":"url","name":"B","url":"https://rookmark-live-test.invalid/b"}
        ]}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a live Chrome profile loads through the Chromium importer")
    func loadsLiveProfile() async throws {
        let url = try writeChromiumProfile()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = OrganizerModel(persistingSessions: false)
        await model.loadProfile(.liveProfile(.chrome, url), discardingSession: false)

        #expect(model.phase == .idle)
        #expect(model.source == .liveProfile(.chrome, url))
        #expect(model.sourceName == "Chrome profile")
        #expect(model.allBookmarks.count == 2)
        #expect(model.sourceSummary?.bookmarkCount == 2)
        // Orion's own irregularity, which a real tree cannot have.
        #expect(model.sourceSummary?.orphanedFolderReferences == nil)
        #expect(model.allBookmarks.first?.originalFolderPath == ["Bookmarks bar"])
    }

    @Test("a live profile that cannot be read rolls the model back and keeps the run")
    func failedLiveProfileRollsBack() async throws {
        let url = try writeChromiumProfile()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = OrganizerModel(persistingSessions: false)
        await model.loadProfile(.liveProfile(.chrome, url), discardingSession: false)
        let bookmark = try #require(model.allBookmarks.first)
        model.updateRows([.init(id: bookmark.id, title: "A", url: bookmark.url,
                                folder: "Development", confidence: 90, modelChoice: nil)])

        // A profile that was there when the card offered it and is gone by the
        // time it loads: the same rollback the file path gets.
        let missing = URL(filePath: "/tmp/rookmark-no-such-profile/places.sqlite")
        await model.loadProfile(.liveProfile(.firefox, missing), discardingSession: false)

        #expect(model.source == .liveProfile(.chrome, url), "the library on screen survives")
        #expect(model.allBookmarks.count == 2)
        #expect(model.rows.map(\.id) == [bookmark.id])
        #expect(model.importFailureMessage != nil)
    }

    @Test("switching profiles with a run on screen is a confirmed replacement")
    func liveProfileConfirmation() {
        let model = OrganizerModel(persistingSessions: false)
        let profile = OrganizerModel.Source.liveProfile(.firefox, URL(filePath: "/tmp/places.sqlite"))
        model.updateSource(.file(export))
        model.updateRows([.init(id: "a", title: "A", url: "https://a.example",
                                folder: "Development", confidence: 90, modelChoice: nil)])

        model.requestProfile(profile)
        #expect(model.pendingProfile == profile, "gated, not loaded")
        #expect(model.source == .file(export), "nothing was read yet")

        model.cancelProfile()
        #expect(model.pendingProfile == nil)
        #expect(model.source == .file(export))

        // Asking for the library already on screen is a no-op, not a reload.
        model.updateSource(profile)
        model.requestProfile(profile)
        #expect(model.pendingProfile == nil)
    }

    // MARK: Safari, the one source that can be visible and unreadable

    /// A Bookmarks.plist in Safari's own nested shape, which
    /// `.liveProfile(.safari, _)` dispatches to. `.invalid` hosts for the same
    /// reason the other fixtures use them.
    private func writeSafariProfile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rookmark-safari-\(UUID().uuidString).plist")
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": "",
            "Children": [
                [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": "BookmarksBar",
                    "Children": [
                        ["WebBookmarkType": "WebBookmarkTypeLeaf",
                         "URLString": "https://rookmark-live-test.invalid/s1",
                         "URIDictionary": ["title": "S1"]],
                        ["WebBookmarkType": "WebBookmarkTypeLeaf",
                         "URLString": "https://rookmark-live-test.invalid/s2",
                         "URIDictionary": ["title": "S2"]],
                    ],
                ],
                // Skipped wholesale, so it must not raise the count.
                ["WebBookmarkType": "WebBookmarkTypeProxy",
                 "Title": "History",
                 "Children": [["WebBookmarkType": "WebBookmarkTypeLeaf",
                               "URLString": "https://rookmark-live-test.invalid/h",
                               "URIDictionary": ["title": "H"]]]],
            ],
        ]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
            .write(to: url)
        return url
    }

    @Test("a live Safari profile loads through the Safari importer")
    func loadsSafariProfile() async throws {
        let url = try writeSafariProfile()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = OrganizerModel(persistingSessions: false)
        await model.loadProfile(.liveProfile(.safari, url), discardingSession: false)

        #expect(model.phase == .idle)
        #expect(model.source == .liveProfile(.safari, url))
        #expect(model.sourceName == "Safari profile")
        #expect(model.allBookmarks.count == 2, "the History proxy contributes nothing")
        #expect(model.sourceSummary?.bookmarkCount == 2)
        #expect(model.allBookmarks.first?.originalFolderPath == ["BookmarksBar"])
        #expect(model.sourceAccess == .allowed)
    }

    /// The welcome grid's Safari card when the file is there but Full Disk
    /// Access is not: nothing is loaded, and the notice carries a settings link
    /// because System Settings is exactly where this gets fixed.
    @Test("a Safari card with no Full Disk Access reports an actionable notice")
    func reportsFullDiskAccess() {
        let model = OrganizerModel(persistingSessions: false)
        #expect(model.sourceAccess == .allowed)

        model.reportFullDiskAccessRequired(for: "Safari")

        guard case .denied(let reason, let showsSettingsLink) = model.sourceAccess else {
            Issue.record("expected .denied, got \(model.sourceAccess)")
            return
        }
        #expect(showsSettingsLink)
        #expect(reason.contains("Full Disk Access"))
        // Nothing was read, and nothing was taken over: this is a notice, not
        // a failure, so the view the user is on stays put.
        #expect(model.source == nil && model.phase == .idle)

        model.dismissSourceAccessNotice()
        #expect(model.sourceAccess == .allowed)
    }

    /// Access revoked between the card offering Safari and the click that
    /// loads it. The rollback is the same one every source gets, plus the
    /// actionable notice, which a plain "import failed" banner cannot carry.
    @Test("a Safari read refused mid-load rolls back and still offers the fix")
    func safariPermissionDeniedDuringLoad() async throws {
        let chromium = try writeChromiumProfile()
        let safari = try writeSafariProfile()
        defer {
            try? FileManager.default.removeItem(at: chromium)
            try? FileManager.default.removeItem(at: safari)
        }

        let model = OrganizerModel(persistingSessions: false)
        await model.loadProfile(.liveProfile(.chrome, chromium), discardingSession: false)
        let bookmark = try #require(model.allBookmarks.first)
        model.updateRows([.init(id: bookmark.id, title: "A", url: bookmark.url,
                                folder: "Development", confidence: 90, modelChoice: nil)])

        // chmod 000 is the closest a test can get to a refused read; TCC
        // itself is not reproducible in a test run.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: safari.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: safari.path(percentEncoded: false)
            )
        }

        await model.loadProfile(.liveProfile(.safari, safari), discardingSession: false)

        #expect(model.source == .liveProfile(.chrome, chromium), "the library on screen survives")
        #expect(model.rows.map(\.id) == [bookmark.id])
        #expect(model.importFailureMessage != nil)
        guard case .denied = model.sourceAccess else {
            Issue.record("expected .denied, got \(model.sourceAccess)")
            return
        }
    }

    /// The regression this guards: a Chromium browser's profile refusal used
    /// to be indistinguishable from "not installed" and fell back silently to
    /// the export card, with no way for the user to discover Full Disk Access
    /// was the actual fix. `isBlockedByPermissions` now asks the importer
    /// instead of hardcoding `false` for every browser but Safari.
    @Test("a Brave read refused mid-load reports the fix, the same as Safari does")
    func chromiumPermissionDeniedDuringLoad() async throws {
        let url = try writeChromiumProfile()
        defer { try? FileManager.default.removeItem(at: url) }

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false)
            )
        }

        let model = OrganizerModel(persistingSessions: false)
        await model.loadProfile(.liveProfile(.brave, url), discardingSession: false)

        #expect(model.source == nil, "nothing loaded")
        guard case .denied(let reason, let showsSettingsLink) = model.sourceAccess else {
            Issue.record("expected .denied, got \(model.sourceAccess)")
            return
        }
        #expect(showsSettingsLink)
        #expect(reason.contains("Brave"), "the notice names the browser that was actually refused")
        #expect(reason.contains("Full Disk Access"))
    }

    /// A source that loads clears a notice left over from a refused one, so
    /// the grid never keeps telling the user to grant something they don't
    /// need any more.
    @Test("loading a readable source clears the access notice")
    func successfulLoadClearsTheNotice() async throws {
        let url = try writeChromiumProfile()
        defer { try? FileManager.default.removeItem(at: url) }

        let model = OrganizerModel(persistingSessions: false)
        model.reportFullDiskAccessRequired(for: "Chrome")
        await model.loadProfile(.liveProfile(.chrome, url), discardingSession: false)

        #expect(model.sourceAccess == .allowed)
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
