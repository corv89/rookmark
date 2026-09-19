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
        /// Accepted, and therefore part of the export. One control rather than a
        /// separate include flag and quality vote: rejecting a placement and
        /// leaving it out of the file are the same intent, and anything that
        /// belongs elsewhere is moved rather than voted down.
        var accepted = true

        var isUnsorted: Bool { folder == Taxonomy.unsorted }
    }

    /// Sentinel for the sidebar's "All" row. A List selection binding cannot
    /// carry nil, so the unfiltered case needs a real value — and it cannot be
    /// the empty string either, which SwiftUI treats as no selection at all.
    /// Never displayed: the row renders its own label.
    static let allFolders = "__rookmark_all__"

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
        /// Stopped part-way with work still outstanding. Distinct from `finished`
        /// so the UI can offer Resume rather than implying the run is done.
        case paused
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
    private(set) var phase: Phase = .idle
    /// Set when a restored run no longer matches the browser, or never finished.
    private(set) var staleness: SessionStore.Staleness?
    private(set) var rows: [Row] = []
    private(set) var folders: [FolderGroup] = []
    private(set) var newFolders: [String] = []
    private(set) var taxonomyFolderCount = 0
    private(set) var lastRunSeconds: Double?
    /// True when the last run was stopped early, so the table is partial.
    private(set) var wasCancelled = false

    // Review state
    var search = ""
    var sort: Sort = .leastConfident
    var selectedFolder: String? = OrganizerModel.allFolders
    var selectedRowID: String?

    private var pinnedTaxonomy: Taxonomy?
    private var rationales: [String: String] = [:]
    /// The detached worker. Held because a detached task does NOT inherit
    /// cancellation from whoever started it, so Stop has to cancel it directly.
    private var runTask: Task<Organizer.Result, Error>?
    /// Titles/URLs for the current run, so streamed decisions (which carry only
    /// a bookmark id) can be turned into rows before the run finishes.
    private var inFlight: [String: Bookmark] = [:]

    var visibleRows: [Row] {
        var out = rows
        if let selectedFolder, selectedFolder != Self.allFolders {
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

    var acceptedCount: Int { rows.count(where: \.accepted) }
    var sortedCount: Int { rows.count { !$0.isUnsorted } }

    var isBusy: Bool {
        switch phase {
        case .scanning, .classifying, .finishing: true
        case .idle, .paused, .finished, .failed: false
        }
    }

    /// Bookmarks in the profile that have no decision yet. This is what Organize
    /// and Resume both work on, so resuming is just "keep going from here".
    var remaining: [Bookmark] {
        let done = Set(rows.map(\.id))
        return allBookmarks.filter { !done.contains($0.id) }
    }

    /// Rate measured on this machine: roughly 1.1s per bookmark, serialized.
    static let secondsPerBookmark = 1.1
    var estimatedSeconds: Double { Double(remaining.count) * Self.secondsPerBookmark }

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
            restoreSession()
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Brings back the last run so quitting never loses work. Rows for bookmarks
    /// that have since left the browser are dropped, so the table always reflects
    /// what is actually there now.
    private func restoreSession() {
        guard let snapshot = SessionStore.load() else { return }

        let liveIDs = Set(allBookmarks.map(\.id))
        rows = snapshot.rows
            .filter { liveIDs.contains($0.id) }
            .map {
                Row(id: $0.id, title: $0.title, url: $0.url, folder: $0.folder,
                    confidence: $0.confidence, modelChoice: $0.modelChoice,
                    accepted: $0.accepted)
            }
        newFolders = snapshot.newFolders

        let state = SessionStore.staleness(of: snapshot, against: allBookmarks)
        staleness = state.isStale ? state : nil
        if !rows.isEmpty { recountFolders() }
    }

    private func saveSession(completed: Bool) {
        guard !rows.isEmpty else { return }
        SessionStore.save(.init(
            savedAt: Date(),
            sourceIDs: allBookmarks.map(\.id),
            rows: rows.map {
                .init(id: $0.id, title: $0.title, url: $0.url, folder: $0.folder,
                      confidence: $0.confidence, modelChoice: $0.modelChoice,
                      accepted: $0.accepted)
            },
            newFolders: newFolders,
            completed: completed
        ))
    }

    /// Throws the saved run away and starts from nothing.
    func discardSession() {
        SessionStore.clear()
        rows = []
        folders = []
        newFolders = []
        staleness = nil
        selectedFolder = Self.allFolders
        selectedRowID = nil
        phase = .idle
    }

    // MARK: - Run

    /// Classifies everything without a decision yet. Starting a fresh run and
    /// resuming a stopped one are the same operation, which is why there is one
    /// button rather than a size picker.
    func organize() async {
        await classify(remaining)
    }

    private func classify(_ sample: [Bookmark]) async {
        guard let taxonomy = pinnedTaxonomy, !sample.isEmpty else { return }

        // Rows already decided are kept: this may be a resume.
        selectedFolder = Self.allFolders
        selectedRowID = nil
        wasCancelled = false
        staleness = nil
        let alreadyDone = rows.count
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

        inFlight = Dictionary(sample.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Report progress across the whole library, not just this leg, so a
        // resumed run continues the count instead of restarting at zero.
        let onProgress: Classifier.ProgressHandler = { [weak self] done, total in
            Task { @MainActor in
                self?.phase = done >= total
                    ? .finishing
                    : .classifying(done: alreadyDone + done, total: alreadyDone + total)
            }
        }

        let onBatch: Classifier.BatchHandler = { [weak self] decisions in
            Task { @MainActor in
                guard let self else { return }
                self.apply(decisions)
                // Snapshot as we go, so a crash or a force-quit costs one batch
                // rather than the whole run.
                self.saveSession(completed: false)
            }
        }

        do {
            // Must run off the main actor. `organize` is nonisolated async, but
            // called directly from this @MainActor method the work can inherit
            // main-actor isolation and block the UI for the whole run — the
            // progress bar then sits still and every queued update flushes at
            // the end. Detaching guarantees it lands on the cooperative pool.
            let work = Task.detached(priority: .userInitiated) {
                try await Organizer().organize(
                    html: html, options: options, progress: onProgress, onBatch: onBatch
                )
            }
            runTask = work
            defer { runTask = nil }
            let result = try await work.value

            // Clustering can mint folders that weren't in the pinned taxonomy.
            let known = Set(taxonomy.names)
            newFolders = result.taxonomy.names.filter { !known.contains($0) }
            for folder in result.taxonomy.folders where rationales[folder.name] == nil {
                rationales[folder.name] = folder.rationale
            }

            // Final reconciliation. Going through `apply` rather than rebuilding
            // the array keeps any include/judgement state set during the run,
            // and settles rows that clustering re-placed after they were shown.
            apply(result.decisions)
            lastRunSeconds = Date().timeIntervalSince(started)
            phase = .finished
            saveSession(completed: remaining.isEmpty)
        } catch is CancellationError {
            // Everything already streamed in stays on screen; only the items the
            // model never reached are missing, and they are absent rather than
            // wrongly filed under Unsorted.
            wasCancelled = true
            recountFolders()
            lastRunSeconds = Date().timeIntervalSince(started)
            phase = remaining.isEmpty ? .finished : .paused
            saveSession(completed: remaining.isEmpty)
        } catch {
            phase = .failed(String(describing: error))
            saveSession(completed: false)
        }
        inFlight = [:]
    }

    /// Merges a batch of decisions into the table while the run continues.
    /// Keyed by bookmark id because Phase 2 clustering re-places items that
    /// first came back Unsorted; appending blindly would leave the stale row
    /// alongside its replacement.
    private func apply(_ decisions: [Classifier.Decision]) {
        for decision in decisions {
            guard let bookmark = inFlight[decision.bookmarkID] else { continue }
            let row = Row(
                id: decision.bookmarkID,
                title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                url: bookmark.url,
                folder: decision.folder,
                confidence: decision.confidence,
                modelChoice: decision.modelChosenFolder != decision.folder
                    ? decision.modelChosenFolder : nil
            )
            if let existing = rows.firstIndex(where: { $0.id == decision.bookmarkID }) {
                // Preserve any judgement or include state the user already set.
                rows[existing] = Row(
                    id: row.id, title: row.title, url: row.url,
                    folder: row.folder, confidence: row.confidence,
                    modelChoice: row.modelChoice,
                    accepted: rows[existing].accepted
                )
            } else {
                rows.append(row)
            }
        }
        recountFolders()
    }

    /// Stops after the current batch, keeping everything classified so far.
    /// Resuming is just `organize()` again, which picks up `remaining`.
    func pause() {
        runTask?.cancel()
    }

    // MARK: - Review actions

    /// Accepting is the single review control: it marks the placement good
    /// and keeps it in the export. Unchecking does both jobs at once.
    func toggleAccepted(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].accepted.toggle()
        saveSession(completed: remaining.isEmpty)
    }

    func move(_ id: String, to folder: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = rows[index]
        rows[index] = Row(
            id: row.id, title: row.title, url: row.url,
            folder: folder, confidence: row.confidence, modelChoice: row.modelChoice,
            accepted: row.accepted
        )
        recountFolders()
        saveSession(completed: remaining.isEmpty)
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
        let byID = Dictionary(uniqueKeysWithValues: rows.filter(\.accepted).map { ($0.id, $0) })
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

    /// Two-tier lookup, because the same binary has to work in the developer's
    /// checkout and in a shipped Rookmark.app:
    ///  1. the source tree, resolved relative to this file — during development
    ///     the app runs via `swift run`, and reading `tuning/` directly means
    ///     taxonomy edits apply without a rebuild;
    ///  2. the copy bundled as a resource (`Resources/`) — the only copy that
    ///     exists once the app leaves this machine. `make-app.sh` packs the
    ///     SwiftPM resource bundle into the .app, so this resolves on any Mac.
    /// Existence (not a decode attempt) decides the tier, so a corrupt
    /// source-tree file surfaces as an error instead of silently loading a
    /// stale bundled copy.
    static func loadPinnedTaxonomy() throws -> Taxonomy {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceTree = repoRoot.appending(path: "tuning/consolidated-taxonomy-v5.json")

        let url: URL
        if FileManager.default.fileExists(atPath: sourceTree.path(percentEncoded: false)) {
            url = sourceTree
        } else if let bundled = Bundle.module.url(
            forResource: "consolidated-taxonomy-v5", withExtension: "json"
        ) {
            url = bundled
        } else {
            throw TaxonomyNotFoundError(searched: [
                sourceTree.path(percentEncoded: false),
                Bundle.module.bundleURL.path(percentEncoded: false),
            ])
        }
        let envelope = try JSONDecoder().decode(TaxonomyEnvelope.self, from: try Data(contentsOf: url))
        return Taxonomy(folders: envelope.folders)
    }

    /// Surfaced through `Phase.failed`, so the message has to say where the app
    /// looked — "no such file" alone would read as a bug with no lead.
    private struct TaxonomyNotFoundError: Error, CustomStringConvertible {
        let searched: [String]
        var description: String {
            "consolidated-taxonomy-v5.json not found; looked in: \(searched.joined(separator: ", "))"
        }
    }
}
