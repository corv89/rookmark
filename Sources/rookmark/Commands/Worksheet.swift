import ArgumentParser
import Foundation
import RookmarkKit

struct Worksheet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate an annotation worksheet from organized bookmarks."
    )

    @Argument(help: "Path to the bookmarks HTML file (used to derive the .db path when --run-id is set).")
    var input: String

    @Option(name: [.short, .customLong("output")], help: "Where to write the CSV worksheet.")
    var output: String?

    @Option(name: .customLong("run-id"), help: "Read from a stateful Store run (includes confidence values). Derives .db path from the input file.")
    var runID: Int64?

    func run() async throws {
        let out = output ?? (input as NSString).deletingPathExtension + ".worksheet.csv"
        var lines: [String] = ["bookmark_id;title;url;assigned_folder;confidence;meta_description;verdict;note"]

        if let runID {
            let dbPath = input + ".db"
            let store = try Store(path: dbPath)
            let bookmarks = try store.all(runID: runID)
            let enrichments = try store.getEnrichments(bookmarkIDs: Set(bookmarks.map(\.id)))
            for b in bookmarks.sorted(by: { $0.id < $1.id }) {
                let folder = (b.assignedFolder ?? "Unsorted")
                    .replacingOccurrences(of: ";", with: ",")
                let title = sanitize(b.title)
                let url = b.url.replacingOccurrences(of: ";", with: ",")
                let conf = b.confidence.map { "\($0)" } ?? ""
                let desc = sanitize(enrichments[b.id]?.metaDescription ?? "")
                lines.append("\(b.id);\(title);\(url);\(folder);\(conf);\(desc);;")
            }
            let csv = lines.joined(separator: "\n") + "\n"
            try csv.write(toFile: out, atomically: true, encoding: .utf8)
            print("Wrote \(bookmarks.count) rows to \(out) (from Store run #\(runID))")
        } else {
            let html = try String(contentsOfFile: input, encoding: .utf8)
            let result = NetscapeBookmarkParser().parse(html)
            for b in result.bookmarks.sorted(by: { $0.id < $1.id }) {
                let folder: String
                if let assigned = b.assignedFolder {
                    folder = assigned
                } else if let first = b.originalFolderPath.first, !first.isEmpty {
                    folder = first
                } else {
                    folder = "Unsorted"
                }
                let title = sanitize(b.title)
                let url = b.url.replacingOccurrences(of: ";", with: ",")
                let sanitizedFolder = folder.replacingOccurrences(of: ";", with: ",")
                let conf = b.confidence.map { "\($0)" } ?? ""
                lines.append("\(b.id);\(title);\(url);\(sanitizedFolder);\(conf);;;")
            }
            let csv = lines.joined(separator: "\n") + "\n"
            try csv.write(toFile: out, atomically: true, encoding: .utf8)
            print("Wrote \(result.bookmarks.count) rows to \(out)")
        }
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
