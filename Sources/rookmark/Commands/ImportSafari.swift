import ArgumentParser
import Foundation
import RookmarkKit

struct ImportSafari: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-safari",
        abstract: "Import bookmarks straight from Safari into a Netscape HTML export."
    )

    @Option(name: [.short, .customLong("output")], help: "Where to write the HTML export. Defaults to safari-import.html")
    var output: String?

    @Option(help: "Read a specific Bookmarks.plist instead of ~/Library/Safari/Bookmarks.plist.")
    var plist: String?

    @Flag(help: "Report what the profile contains without writing anything.")
    var dryRun = false

    func run() async throws {
        let result: SafariImporter.Result
        if let plist {
            result = try SafariImporter.importBookmarks(at: URL(filePath: plist))
        } else {
            guard let url = SafariImporter.defaultBookmarksURL() else {
                // Unlike every other browser, "can't read it" here is not the
                // end of the road: Full Disk Access is granted by hand and
                // only the user can do it, so say so instead of suggesting a
                // manual export.
                guard !SafariImporter.isBlockedByFullDiskAccess() else {
                    throw ValidationError("""
                        Safari's bookmarks are behind Full Disk Access.
                        Open System Settings ▸ Privacy & Security ▸ Full Disk Access and add the program running this command \
                        (Terminal, iTerm, or Rookmark.app), then run it again.
                        """)
                }
                throw ValidationError("No Safari bookmarks found at ~/Library/Safari/Bookmarks.plist. Pass --plist to point at one directly.")
            }
            FileHandle.standardError.write(Data("Reading \(url.path(percentEncoded: false))\n".utf8))
            result = try SafariImporter.importBookmarks(at: url)
        }

        let summary = result.summary
        print("Safari bookmarks:")
        print("  Bookmarks:        \(summary.bookmarkCount)")
        print("  Folders:          \(summary.folderCount)")
        if summary.duplicatesSkipped > 0 {
            print("  Duplicates:       \(summary.duplicatesSkipped) skipped (same normalized URL)")
        }

        guard !dryRun else { return }

        let path = output ?? "safari-import.html"
        let html = NetscapeBookmarkWriter().write(result.parse.bookmarks)
        try html.write(to: URL(filePath: path), atomically: true, encoding: .utf8)
        print("\nWrote \(result.parse.bookmarks.count) bookmarks to \(path)")
        print("Next: rookmark organize \(path) --taxonomy-from tuning/consolidated-taxonomy-v5.json --cluster --no-enrich")
    }
}
