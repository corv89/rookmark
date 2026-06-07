import ArgumentParser
import Foundation
import LazyBookmarksKit

struct Dedup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find duplicate bookmarks.")
    @Argument var input: String
    func run() async throws {
        let html = try String(contentsOfFile: input, encoding: .utf8)
        let result = NetscapeBookmarkParser().parse(html)
        let groups = URLNormalizer.findDuplicates(result.bookmarks)

        if groups.isEmpty {
            print("No duplicates found.")
            return
        }

        for group in groups {
            let label = group.tier == .exact ? "EXACT" : "FUZZY"
            print("[\(label)]")
            for b in group.bookmarks {
                print("  \(b.title.isEmpty ? "(untitled)" : b.title) — \(b.url)")
            }
            print()
        }
        let total = groups.reduce(0) { $0 + $1.bookmarks.count }
        print("\(groups.count) duplicate groups, \(total) bookmarks involved.")
    }
}

struct CheckLinks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check-links",
        abstract: "Find dead links via native async HEAD/GET.")
    @Argument var input: String
    @Option var concurrency: Int = 8
    func run() async throws {
        let html = try String(contentsOfFile: input, encoding: .utf8)
        let result = NetscapeBookmarkParser().parse(html)
        let checker = LinkChecker(concurrency: concurrency)
        let reports = await checker.check(result.bookmarks)

        let dead = reports.filter { $0.status == .dead }
        let redirected = reports.filter { $0.status == .redirected }
        let alive = reports.filter { $0.status == .alive }

        if !dead.isEmpty {
            print("Dead links (\(dead.count)):")
            let byID = Dictionary(uniqueKeysWithValues: result.bookmarks.map { ($0.id, $0) })
            for r in dead {
                let bm = byID[r.bookmarkID]
                print("  \(bm?.title ?? r.bookmarkID) — \(bm?.url ?? "")")
            }
            print()
        }

        print("Summary: \(alive.count) alive, \(dead.count) dead, \(redirected.count) redirected, \(reports.count - alive.count - dead.count - redirected.count) unknown")
    }
}

struct ImportCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import",
        abstract: "Import an HTML export into the SQLite store.")
    @Argument var input: String
    @Option var db: String = "lazybm.sqlite"
    func run() async throws {
        let store = try Store(path: db)
        let html = try String(contentsOfFile: input, encoding: .utf8)
        let result = NetscapeBookmarkParser().parse(html)
        let runID = try store.createRun(sourcePath: input)
        try store.upsert(result.bookmarks, runID: runID)
        print("Imported \(result.bookmarks.count) bookmarks (run #\(runID)).")
    }
}

struct ExportCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export",
        abstract: "Export the store back to Netscape HTML.")
    @Option(name: [.short, .customLong("output")]) var output: String?
    @Option var runID: Int64?
    @Option var db: String = "lazybm.sqlite"
    func run() async throws {
        let store = try Store(path: db)
        guard let id = runID else {
            print("Specify --run-id.")
            throw ExitCode.failure
        }
        var bookmarks = try store.all(runID: id)
        for i in bookmarks.indices {
            if bookmarks[i].assignedFolder == nil {
                bookmarks[i].assignedFolder = Taxonomy.unsorted
            }
        }
        let html = NetscapeBookmarkWriter().write(bookmarks)
        let out = output ?? "export.html"
        try html.write(toFile: out, atomically: true, encoding: .utf8)
        print("Exported \(bookmarks.count) bookmarks to \(out).")
    }
}

struct ListCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list",
        abstract: "List stored bookmarks.")
    @Option var runID: Int64?
    @Option var db: String = "lazybm.sqlite"
    func run() async throws {
        let store = try Store(path: db)
        guard let id = runID else {
            print("Specify --run-id.")
            throw ExitCode.failure
        }
        let bookmarks = try store.all(runID: id)
        for b in bookmarks {
            let folder = b.assignedFolder ?? "-"
            print("[\(folder)] \(b.title.isEmpty ? "(untitled)" : b.title) — \(b.url)")
        }
        print("\(bookmarks.count) bookmarks.")
    }
}

struct SearchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search",
        abstract: "Search stored bookmarks.")
    @Argument var query: String
    @Option var runID: Int64?
    @Option var db: String = "lazybm.sqlite"
    func run() async throws {
        let store = try Store(path: db)
        guard let id = runID else {
            print("Specify --run-id.")
            throw ExitCode.failure
        }
        let bookmarks = try store.all(runID: id)
        let q = query.lowercased()
        let matches = bookmarks.filter {
            $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) ||
            ($0.assignedFolder?.lowercased().contains(q) ?? false)
        }
        for b in matches {
            let folder = b.assignedFolder ?? "-"
            print("[\(folder)] \(b.title.isEmpty ? "(untitled)" : b.title) — \(b.url)")
        }
        print("\(matches.count) matches.")
    }
}

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Revert the last organize run.")
    @Option var runID: Int64?
    @Option var db: String = "lazybm.sqlite"
    func run() async throws {
        let store = try Store(path: db)
        guard let id = runID else {
            print("Specify --run-id.")
            throw ExitCode.failure
        }
        let ok = try store.undoLast(runID: id)
        print(ok ? "Undo complete." : "No snapshot to undo.")
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show last-run summary and resume state.")
    @Option var runID: Int64?
    @Option var db: String = "lazybm.sqlite"
    func run() async throws {
        let store = try Store(path: db)
        guard let id = runID else {
            print("Specify --run-id.")
            throw ExitCode.failure
        }
        let all = try store.all(runID: id)
        let committed = all.filter { $0.confidence != nil }.count
        let uncommitted = all.count - committed
        print("Run #\(id): \(all.count) bookmarks total, \(committed) classified, \(uncommitted) pending.")
    }
}
