import ArgumentParser
import Foundation
import RookmarkKit

struct ImportOrion: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-orion",
        abstract: "Import bookmarks straight from the installed Orion browser into a Netscape HTML export."
    )

    @Option(name: [.short, .customLong("output")], help: "Where to write the HTML export. Defaults to orion-import.html")
    var output: String?

    @Option(help: "Read a specific favourites.plist instead of auto-detecting the Orion profile.")
    var plist: String?

    @Flag(help: "Report what the profile contains without writing anything.")
    var dryRun = false

    func run() async throws {
        let result: OrionImporter.Result
        if let plist {
            result = try OrionImporter.importFavourites(at: URL(filePath: plist))
        } else {
            guard let url = OrionImporter.defaultFavouritesURL() else {
                throw ValidationError("No Orion profile found. Pass --plist to point at a favourites.plist directly.")
            }
            FileHandle.standardError.write(Data("Reading \(url.path(percentEncoded: false))\n".utf8))
            result = try OrionImporter.importFavourites(at: url)
        }

        let summary = result.summary
        print("Orion profile:")
        print("  Bookmarks:        \(summary.bookmarkCount)")
        print("  Folders:          \(summary.folderCount)")
        print("  In a real folder: \(summary.withResolvedFolder)")
        if summary.orphanedFolderReferences > 0 {
            print("  Orphaned:         \(summary.orphanedFolderReferences) bookmarks point at \(summary.missingFolderIDs) folders that no longer exist")
            print("                    (imported at root; the source's folder structure is already broken)")
        }
        if summary.duplicatesSkipped > 0 {
            print("  Duplicates:       \(summary.duplicatesSkipped) skipped (same normalized URL)")
        }

        guard !dryRun else { return }

        let path = output ?? "orion-import.html"
        let html = NetscapeBookmarkWriter().write(result.parse.bookmarks)
        try html.write(to: URL(filePath: path), atomically: true, encoding: .utf8)
        print("\nWrote \(result.parse.bookmarks.count) bookmarks to \(path)")
        print("Next: rookmark organize \(path) --taxonomy-from tuning/consolidated-taxonomy-v5.json --cluster --no-enrich")
    }
}
