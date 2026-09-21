import ArgumentParser
import Foundation
import RookmarkKit

struct ImportFirefox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-firefox",
        abstract: "Import bookmarks straight from the installed Firefox browser into a Netscape HTML export."
    )

    @Option(name: [.short, .customLong("output")], help: "Where to write the HTML export. Defaults to firefox-import.html")
    var output: String?

    @Option(help: "Read a specific places.sqlite instead of auto-detecting the Firefox profile.")
    var places: String?

    @Flag(help: "Report what the profile contains without writing anything.")
    var dryRun = false

    func run() async throws {
        let result: FirefoxImporter.Result
        if let places {
            result = try FirefoxImporter.importBookmarks(at: URL(filePath: places))
        } else {
            guard let url = FirefoxImporter.defaultPlacesURL() else {
                if FirefoxImporter.isBlockedByFullDiskAccess() {
                    throw ValidationError("Firefox's bookmarks are behind Full Disk Access. Grant it to this binary in System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again.")
                }
                throw ValidationError("No Firefox profile found. Pass --places to point at a places.sqlite directly.")
            }
            FileHandle.standardError.write(Data("Reading \(url.path(percentEncoded: false))\n".utf8))
            result = try FirefoxImporter.importBookmarks(at: url)
        }

        let summary = result.summary
        print("Firefox profile:")
        print("  Bookmarks:        \(summary.bookmarkCount)")
        print("  Folders:          \(summary.folderCount)")
        if summary.duplicatesSkipped > 0 {
            print("  Duplicates:       \(summary.duplicatesSkipped) skipped (same normalized URL)")
        }

        guard !dryRun else { return }

        let path = output ?? "firefox-import.html"
        let html = NetscapeBookmarkWriter().write(result.parse.bookmarks)
        try html.write(to: URL(filePath: path), atomically: true, encoding: .utf8)
        print("\nWrote \(result.parse.bookmarks.count) bookmarks to \(path)")
        print("Next: rookmark organize \(path) --taxonomy-from tuning/consolidated-taxonomy-v5.json --cluster --no-enrich")
    }
}
