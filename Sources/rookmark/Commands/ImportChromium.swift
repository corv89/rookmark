import ArgumentParser
import Foundation
import RookmarkKit

/// Conformance lives here rather than in the kit, which has no business
/// importing ArgumentParser: `Product` is already `String`-raw-valued and
/// `CaseIterable`, so the default implementation supplies both parsing and the
/// value list in `--help`.
extension ChromiumImporter.Product: ExpressibleByArgument {}

struct ImportChromium: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-chromium",
        abstract: "Import bookmarks straight from an installed Chrome, Brave, Edge or Vivaldi profile into a Netscape HTML export."
    )

    @Option(help: "Which Chromium-based browser to read.")
    var browser: ChromiumImporter.Product = .chrome

    @Option(name: [.short, .customLong("output")], help: "Where to write the HTML export. Defaults to <browser>-import.html")
    var output: String?

    @Option(help: "Read a specific Bookmarks file instead of auto-detecting the profile.")
    var bookmarks: String?

    @Flag(help: "Report what the profile contains without writing anything.")
    var dryRun = false

    func run() async throws {
        let result: ChromiumImporter.Result
        if let bookmarks {
            result = try ChromiumImporter.importBookmarks(at: URL(filePath: bookmarks), for: browser)
        } else {
            guard let url = ChromiumImporter.defaultBookmarksURL(for: browser) else {
                if ChromiumImporter.isBlockedByFullDiskAccess(for: browser) {
                    throw ValidationError("\(browser.displayName)'s bookmarks are behind Full Disk Access. Grant it to this binary in System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again.")
                }
                throw ValidationError("No \(browser.displayName) profile found. Pass --bookmarks to point at a Bookmarks file directly.")
            }
            FileHandle.standardError.write(Data("Reading \(url.path(percentEncoded: false))\n".utf8))
            result = try ChromiumImporter.importBookmarks(at: url, for: browser)
        }

        let summary = result.summary
        print("\(browser.displayName) profile:")
        print("  Bookmarks:        \(summary.bookmarkCount)")
        print("  Folders:          \(summary.folderCount)")
        if summary.duplicatesSkipped > 0 {
            print("  Duplicates:       \(summary.duplicatesSkipped) skipped (same normalized URL)")
        }

        guard !dryRun else { return }

        let path = output ?? "\(browser.rawValue)-import.html"
        let html = NetscapeBookmarkWriter().write(result.parse.bookmarks)
        try html.write(to: URL(filePath: path), atomically: true, encoding: .utf8)
        print("\nWrote \(result.parse.bookmarks.count) bookmarks to \(path)")
        print("Next: rookmark organize \(path) --taxonomy-from tuning/consolidated-taxonomy-v5.json --cluster --no-enrich")
    }
}
