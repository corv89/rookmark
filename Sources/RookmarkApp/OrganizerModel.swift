import Foundation
import RookmarkKit
import Observation

@MainActor
@Observable
final class OrganizerModel {

    struct Row: Identifiable {
        let id: String
        let title: String
        let url: String
        let folder: String
        let confidence: Int
        /// What the model picked before the confidence floor could demote it.
        /// Explains items that landed in Unsorted despite the model having a view.
        let modelChoice: String?
        /// Included in the export. The real product control — distinct from the
        /// thumbs, which only record the presenter's judgement of quality.
        var included = true
        var accepted: Bool?

        var isUnsorted: Bool { folder == Taxonomy.unsorted }
    }

    struct FolderGroup: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        let rationale: String
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case classifying(done: Int, total: Int)
        /// Classification is done but clustering and folder-naming still are not.
        /// Without this the bar sits at 100% looking hung.
        case finishing
        case finished
        case failed(String)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case leastConfident = "Least confident"
        case folder = "Folder"
        case title = "Title"
        var id: String { rawValue }
    }

    // Profile
    private(set) var summary: OrionImporter.Summary?
    private(set) var allBookmarks: [Bookmark] = []

    // Run
    var sampleSize = 60
    private(set) var phase: Phase = .idle
    private(set) var rows: [Row] = []
    private(set) var folders: [FolderGroup] = []
    private(set) var newFolders: [String] = []
    private(set) var taxonomyFolderCount = 0
    private(set) var lastRunSeconds: Double?

    // Review state
    var search = ""
    var sort: Sort = .leastConfident
    var selectedFolder: String?
    var selectedRowID: String?

    private var pinnedTaxonomy: Taxonomy?
    private var rationales: [String: String] = [:]

    var visibleRows: [Row] {
        var out = rows
        if let selectedFolder {
            out = out.filter { $0.folder == selectedFolder }
        }
        if !search.isEmpty {
            out = out.filter {
                $0.title.localizedCaseInsensitiveContains(search)
                    || $0.url.localizedCaseInsensitiveContains(search)
            }
        }
        switch sort {
        case .leastConfident: out.sort { $0.confidence < $1.confidence }
        case .folder: out.sort { ($0.folder, $0.title) < ($1.folder, $1.title) }
        case .title: out.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return out
    }

    var selectedRow: Row? {
        guard let selectedRowID else { return nil }
        return rows.first { $0.id == selectedRowID }
    }

    func rationale(for folder: String) -> String? { rationales[folder] }

    var includedCount: Int { rows.count { $0.included } }
    var sortedCount: Int { rows.count { !$0.isUnsorted } }

    var judged: (accepted: Int, rejected: Int) {
        rows.reduce(into: (0, 0)) { counts, row in
            switch row.accepted {
            case true: counts.0 += 1
            case false: counts.1 += 1
            case nil: break
            }
        }
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .classifying, .finishing: true
        case .idle, .finished, .failed: false
        }
    }

    /// Rate measured on this machine: roughly 1.1s per bookmark, serialized.
    static let secondsPerBookmark = 1.1
    var estimatedSeconds: Double { Double(sampleSize) * Self.secondsPerBookmark }
    var estimatedSecondsForAll: Double { Double(allBookmarks.count) * Self.secondsPerBookmark }

    // MARK: - Scan

    func scan() async {
        phase = .scanning
        do {
            guard let url = OrionImporter.defaultFavouritesURL() else {
                phase = .failed("No Orion profile found in ~/Library/Application Support/Orion.")
                return
            }
            let imported = try OrionImporter.importFavourites(at: url)
            allBookmarks = imported.parse.bookmarks
            summary = imported.summary

            let taxonomy = try Self.loadPinnedTaxonomy()
            pinnedTaxonomy = taxonomy
            taxonomyFolderCount = taxonomy.folders.count
            rationales = Dictionary(
                taxonomy.folders.map { ($0.name, $0.rationale) },
                uniquingKeysWith: { first, _ in first }
            )
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    // MARK: - Run

    /// A random sample, so nothing is cherry-picked.
    func classifySample() async {
        await classify(Array(allBookmarks.shuffled().prefix(sampleSize)))
    }

    func classifyAll() async {
        await classify(allBookmarks)
    }

    private func classify(_ sample: [Bookmark]) async {
        guard let taxonomy = pinnedTaxonomy, !sample.isEmpty else { return }

        rows = []
        folders = []
        newFolders = []
        selectedFolder = nil
        selectedRowID = nil
        phase = .classifying(done: 0, total: sample.count)
        let started = Date()

        let html = NetscapeBookmarkWriter().write(sample)
        let options = Organizer.Options(
            stateful: false,
            clustering: ClusteringConfig(enabled: true),
            embedderPreference: .contextual,
            pinnedTaxonomy: taxonomy,
            enrich: false          // never block the run on the network
        )

        let onProgress: Classifier.ProgressHandler = { [weak self] done, total in
            Task { @MainActor in
                self?.phase = done >= total ? .finishing : .classifying(done: done, total: total)
            }
        }

        do {
            // Must run off the main actor. `organize` is nonisolated async, but
            // called directly from this @MainActor method the work can inherit
            // main-actor isolation and block the UI for the whole run — the
            // progress bar then sits still and every queued update flushes at
            // the end. Detaching guarantees it lands on the cooperative pool.
            let result = try await Task.detached(priority: .userInitiated) {
                try await Organizer().organize(html: html, options: options, progress: onProgress)
            }.value

            // Clustering can mint folders that weren't in the pinned taxonomy.
            let known = Set(taxonomy.names)
            newFolders = result.taxonomy.names.filter { !known.contains($0) }
            for folder in result.taxonomy.folders where rationales[folder.name] == nil {
                rationales[folder.name] = folder.rationale
            }

            let choiceByID = Dictionary(
                result.decisions.map { ($0.bookmarkID, $0.modelChosenFolder) },
                uniquingKeysWith: { first, _ in first }
            )

            rows = result.bookmarks.map { bookmark in
                let folder = bookmark.assignedFolder ?? Taxonomy.unsorted
                let choice = choiceByID[bookmark.id] ?? nil
                return Row(
                    id: bookmark.id,
                    title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                    url: bookmark.url,
                    folder: folder,
                    confidence: bookmark.confidence ?? 0,
                    modelChoice: (choice != folder) ? choice : nil
                )
            }

            folders = Dictionary(grouping: rows, by: \.folder)
                .map { FolderGroup(name: $0.key, count: $0.value.count, rationale: rationales[$0.key] ?? "") }
                .sorted {
                    // Unsorted always last; otherwise biggest first.
                    if $0.name == Taxonomy.unsorted { return false }
                    if $1.name == Taxonomy.unsorted { return true }
                    return ($0.count, $1.name) > ($1.count, $0.name)
                }

            lastRunSeconds = Date().timeIntervalSince(started)
            phase = .finished
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    // MARK: - Review actions

    func judge(_ id: String, accepted: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].accepted = rows[index].accepted == accepted ? nil : accepted
    }

    func toggleIncluded(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].included.toggle()
    }

    func move(_ id: String, to folder: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = rows[index]
        rows[index] = Row(
            id: row.id, title: row.title, url: row.url,
            folder: folder, confidence: row.confidence, modelChoice: row.modelChoice,
            included: row.included, accepted: row.accepted
        )
        recountFolders()
    }

    private func recountFolders() {
        let counts = Dictionary(grouping: rows, by: \.folder).mapValues(\.count)
        var names = Set(folders.map(\.name))
        names.formUnion(counts.keys)
        folders = names.map { FolderGroup(name: $0, count: counts[$0] ?? 0, rationale: rationales[$0] ?? "") }
            .filter { $0.count > 0 }
            .sorted {
                if $0.name == Taxonomy.unsorted { return false }
                if $1.name == Taxonomy.unsorted { return true }
                return ($0.count, $1.name) > ($1.count, $0.name)
            }
    }

    /// Writes a *new* HTML file. The live browser is never touched.
    func exportOrganized() throws -> URL {
        let byID = Dictionary(uniqueKeysWithValues: rows.filter(\.included).map { ($0.id, $0) })
        let organized = allBookmarks.compactMap { bookmark -> Bookmark? in
            guard let row = byID[bookmark.id] else { return nil }
            var copy = bookmark
            copy.assignedFolder = row.folder
            copy.confidence = row.confidence
            return copy
        }
        let url = URL.downloadsDirectory.appending(path: "rookmark-orion.organized.html")
        try NetscapeBookmarkWriter().write(organized).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Taxonomy

    /// Resolved relative to this source file: the app runs from the developer's
    /// checkout via `swift run`. A shipping build would carry it as a resource.
    private static func loadPinnedTaxonomy() throws -> Taxonomy {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appending(path: "tuning/consolidated-taxonomy-v5.json")
        let envelope = try JSONDecoder().decode(TaxonomyEnvelope.self, from: try Data(contentsOf: url))
        return Taxonomy(folders: envelope.folders)
    }
}
