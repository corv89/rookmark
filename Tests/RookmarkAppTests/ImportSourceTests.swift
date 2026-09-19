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
    }

    @Test("a non-export is refused with a message that names the file")
    func refusesNonExport() throws {
        let model = OrganizerModel()
        model.requestImport(from: URL(filePath: "/tmp/exports/bookmarks.json"))
        guard case .failed(let message) = model.phase else {
            return Issue.record("expected .failed, got \(model.phase)")
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
                <DT><A HREF="https://swift.org/">Swift</A>
                <DT><A HREF="https://example.org/rookmark-import-test/b">Example</A>
            </DL><p>
        </DL><p>
        """)
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
        let model = OrganizerModel()
        await model.importFile(at: url, discardingSession: false)
        guard case .failed(let message) = model.phase else {
            return Issue.record("expected .failed, got \(model.phase)")
        }
        #expect(message.contains(url.lastPathComponent))
    }
}
