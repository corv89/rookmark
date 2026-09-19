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

    /// Where the bookmarks under review came from. Launch reads the installed
    /// Orion profile; a user-initiated import reads any Netscape-format export.
    /// The pipeline downstream of this (parse -> taxonomy -> classify -> export)
    /// is identical for both, because ids are derived from the normalized URL.
    enum Source: Equatable {
        case orionProfile
        case file(URL)

        /// What the sidebar calls it. Requirement: the user can always tell which
        /// library is loaded.
        var name: String {
            switch self {
            case .orionProfile: "Orion profile"
            case .file(let url): url.lastPathComponent
            }
        }
    }

    /// What the UI needs to know about the on-device model: the notice text
    /// and whether System Settings can change the outcome. The kit reports a
    /// described reason string (`SessionFactory.describe`); deciding what the
    /// app does about each reason is presentation, so the mapping lives here.
    enum ModelAvailability: Equatable {
        case available
        case unavailable(reason: String, showsSettingsLink: Bool)

        init(_ availability: SessionFactory.Availability) {
            switch availability {
            case .available:
                self = .available
            case .unavailable(let reason):
                // Every reason can be acted on from the Apple Intelligence &
                // Siri pane (off → turn on, not ready → watch the download)
                // except an ineligible Mac, where there is nothing to enable.
                // That wording is `SessionFactory.describe(.deviceNotEligible)`
                // — the kit's stable string — matched by prefix so trailing
                // edits don't break it.
                self = .unavailable(
                    reason: reason,
                    showsSettingsLink: !reason.hasPrefix(Self.ineligiblePrefix)
                )
            }
        }

        /// ASCII apostrophe, byte-identical to SessionFactory.swift:58.
        private static let ineligiblePrefix = "This Mac isn't eligible"
    }

    // Profile
    private(set) var source: Source?
    private(set) var allBookmarks: [Bookmark] = []
    /// Counts the sidebar shows about whatever source is loaded. Nil until one is.
    /// Orion reports its own file's irregularities; a generic export has none to
    /// report, hence the optional.
    private(set) var sourceSummary: SourceSummary?

    struct SourceSummary: Equatable {
        var bookmarkCount: Int
        /// Orion only: bookmarks whose parent folder entry is missing.
        var orphanedFolderReferences: Int?
    }

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
    /// A file import waiting on the replace confirmation. Non-nil drives the
    /// dialog; the load has not started.
    private(set) var pendingImport: URL?
    /// Set when an import failed while a run was on screen: the run survives, so
    /// the failure is reported as a dismissible banner in ContentView instead of
    /// taking over the whole detail view (`.failed` is reserved for failures with
    /// nothing to protect). Cleared by `dismissImportFailure()`.
    private(set) var importFailureMessage: String?
    /// An Orion switch waiting on the replace confirmation, mirroring
    /// `pendingImport` for the profile path. Non-nil drives the dialog; the load
    /// has not started.
    private(set) var pendingOrionProfile = false
    /// On-device model availability, re-read at scan time and on every app
    /// activation. Never latch a result: Apple Intelligence can be turned on
    /// while Rookmark is running.
    private(set) var availability: SessionFactory.Availability = .available

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

    /// Derived, so a re-check refreshes the UI automatically.
    var modelAvailability: ModelAvailability { ModelAvailability(availability) }

    /// Gates the Organize control: the run cannot succeed without the model.
    var isModelAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    var sourceName: String { source?.name ?? "" }

    /// Export file stem. Orion keeps its historical name; a file run is named for
    /// its file so two sources never write over each other's export.
    private var exportStem: String {
        switch source {
        case .orionProfile, nil: "orion"
        case .file(let url): url.deletingPathExtension().lastPathComponent
        }
    }

    /// Production path: `SessionFactory` is Sendable and the check is a cheap
    /// synchronous status read (same call `doctor` makes).
    func refreshModelAvailability() {
        availability = SessionFactory().availability()
    }

    /// State-update half split out so tests can drive it without the real
    /// model — FoundationModels cannot run in CI.
    func updateAvailability(_ newValue: SessionFactory.Availability) {
        availability = newValue
    }

    /// Only html/htm exports are importable; both drag-and-drop and the open
    /// panel gate through this so the two paths cannot disagree.
    static func isImportableFile(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Importing a file replaces the run on screen, which is a destructive act, so
    /// it needs the user's OK. Re-opening the very file the current run came from
    /// is the exception: that is a reload, and the saved rows come back.
    func importRequiresConfirmation(for url: URL) -> Bool {
        guard !rows.isEmpty else { return false }
        if case .file(let current) = source, current == url { return false }
        return true
    }

    /// Entry point for both the drop and the open panel. Either gates on the
    /// confirmation above or starts the load; nothing is read before the gate.
    func requestImport(from url: URL) {
        guard !isBusy else { return }                    // the UI rejects the drag first
        guard Self.isImportableFile(url) else {
            reportImportFailure("\(url.lastPathComponent) is not a bookmarks export. Expected an .html or .htm file.")
            return
        }
        if importRequiresConfirmation(for: url) {
            pendingImport = url
        } else {
            Task { await importFile(at: url, discardingSession: false) }
        }
    }

    func confirmImport() {
        guard let url = pendingImport else { return }
        pendingImport = nil
        Task { await importFile(at: url, discardingSession: true) }
    }

    func cancelImport() { pendingImport = nil }

    /// Where a refused or failed import lands: with a run on screen the run is
    /// kept and the failure becomes the dismissible banner; with nothing on
    /// screen the failure is the whole story and `.failed` shows.
    private func reportImportFailure(_ message: String) {
        if rows.isEmpty {
            phase = .failed(message)
        } else {
            importFailureMessage = message
        }
    }

    func dismissImportFailure() { importFailureMessage = nil }

    /// The toolbar's way back to the Orion library, so leaving an imported file
    /// never needs a relaunch. Guards mirror requestImport(from:): nothing during
    /// a run, and a run on screen is replaced only after confirmation.
    func requestOrionProfile() {
        guard !isBusy else { return }
        guard case .orionProfile = source else {
            if rows.isEmpty {
                Task { await load(.orionProfile, discardingSession: false) }
            } else {
                pendingOrionProfile = true
            }
            return
        }
    }

    func confirmOrionProfile() {
        guard pendingOrionProfile else { return }
        pendingOrionProfile = false
        Task { await load(.orionProfile, discardingSession: true) }
    }

    func cancelOrionProfile() { pendingOrionProfile = false }

    // State-update halves split out so tests can drive the import gate without a
    // real load: drag-and-drop and NSOpenPanel cannot run in CI, and neither can
    // the model. Mirrors updateAvailability(_:).
    func updateSource(_ newValue: Source?) { source = newValue }
    func updateRows(_ newValue: [Row]) { rows = newValue }

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

    /// Launch path: read the installed Orion profile when there is one. A machine
    /// without Orion is not an error; `source` stays nil and the UI offers the
    /// drop-target empty state instead.
    func scan() async {
        await load(.orionProfile, discardingSession: false)
    }

    /// User-initiated import of a bookmarks HTML export. `discardingSession` is
    /// true only on the confirmed-replacement path.
    func importFile(at url: URL, discardingSession: Bool) async {
        await load(.file(url), discardingSession: discardingSession)
    }

    private func load(_ newSource: Source, discardingSession: Bool) async {
        refreshModelAvailability()
        // Rollback snapshot: if the new source cannot be read, the model returns to
        // exactly this state. Chosen over leaving an "honest empty" model because a
        // failed import over a live run must leave that run intact (T3 review,
        // majors 1 and 3); rolling back to an empty prior state covers the
        // nothing-on-screen case with the same code.
        let previous = (
            source: source, allBookmarks: allBookmarks, sourceSummary: sourceSummary,
            rows: rows, folders: folders, newFolders: newFolders, staleness: staleness,
            wasCancelled: wasCancelled, lastRunSeconds: lastRunSeconds,
            selectedFolder: selectedFolder, selectedRowID: selectedRowID,
            search: search, sort: sort, phase: phase,
            pinnedTaxonomy: pinnedTaxonomy, taxonomyFolderCount: taxonomyFolderCount,
            rationales: rationales
        )
        // The run on screen belongs to the previous source. Clearing first means
        // the scanning state never shows old rows under a new source name.
        source = newSource
        rows = []
        folders = []
        newFolders = []
        staleness = nil
        selectedFolder = Self.allFolders
        selectedRowID = nil
        search = ""                       // stale review filters belong to the old run
        sort = .leastConfident
        importFailureMessage = nil        // a retry that succeeds clears the banner
        wasCancelled = false
        lastRunSeconds = nil
        phase = .scanning
        do {
            switch newSource {
            case .orionProfile:
                guard let url = OrionImporter.defaultFavouritesURL() else {
                    // No profile: not a failure. Nothing is loaded and the
                    // drop-target empty state takes over.
                    source = nil
                    allBookmarks = []
                    sourceSummary = nil
                    phase = .idle
                    return
                }
                let imported = try await Task.detached(priority: .userInitiated) {
                    try OrionImporter.importFavourites(at: url)
                }.value
                allBookmarks = imported.parse.bookmarks
                sourceSummary = SourceSummary(
                    bookmarkCount: imported.summary.bookmarkCount,
                    orphanedFolderReferences: imported.summary.orphanedFolderReferences
                )
            case .file(let url):
                // Parse only, exactly like the CLI: read the bytes, never write to
                // the file, never fetch anything a bookmark points at. The isFileURL
                // guard keeps that promise for remote URLs, which isImportableFile
                // alone does not catch ("https://host/x.html" has a html extension).
                let parse = try await Task.detached(priority: .userInitiated) { () throws -> ParseResult in
                    guard url.isFileURL else { throw NonFileImportError(url: url) }
                    let html = try String(contentsOf: url, encoding: .utf8)
                    return NetscapeBookmarkParser().parse(html)
                }.value
                guard !parse.bookmarks.isEmpty else { throw ImportError(file: url) }
                allBookmarks = parse.bookmarks
                sourceSummary = SourceSummary(bookmarkCount: parse.bookmarks.count)
            }

            // Only now, with the new source actually readable, does the confirmed
            // replacement throw the old run away — a failed import must not.
            if discardingSession { SessionStore.clear() }

            let taxonomy = try Self.loadPinnedTaxonomy()
            pinnedTaxonomy = taxonomy
            taxonomyFolderCount = taxonomy.folders.count
            rationales = Dictionary(
                taxonomy.folders.map { ($0.name, $0.rationale) },
                uniquingKeysWith: { first, _ in first }
            )
            // Ids are content-derived, so this restores a file-sourced snapshot by
            // the same rule as an Orion one: matching ids come back, the rest count
            // as drift. Note that launch still scans Orion first, so a file run is
            // only fully restored once its file is imported again.
            restoreSession()
            phase = .idle
        } catch {
            // The new source never loaded. Roll the whole model back rather than
            // show the old library under the new source's name: with rows cleared
            // but allBookmarks stale, `remaining` would re-arm Organize against the
            // old library under the dropped file's export stem (T3 review, major 1).
            source = previous.source
            allBookmarks = previous.allBookmarks
            sourceSummary = previous.sourceSummary
            rows = previous.rows
            folders = previous.folders
            newFolders = previous.newFolders
            staleness = previous.staleness
            wasCancelled = previous.wasCancelled
            lastRunSeconds = previous.lastRunSeconds
            selectedFolder = previous.selectedFolder
            selectedRowID = previous.selectedRowID
            search = previous.search
            sort = previous.sort
            pinnedTaxonomy = previous.pinnedTaxonomy
            taxonomyFolderCount = previous.taxonomyFolderCount
            rationales = previous.rationales
            let message = String(describing: error)
            if rows.isEmpty {
                // Nothing on screen to protect: the failure is the whole story and
                // the full-detail failed notice (with its Start over button) shows.
                phase = .failed(message)
            } else {
                // A run is on screen: keep it, keep its phase, report the failure
                // as a dismissible banner instead (T3 review, major 3).
                phase = previous.phase
                importFailureMessage = message
            }
        }
    }

    private struct ImportError: Error, CustomStringConvertible {
        let file: URL
        var description: String {
            "No bookmarks found in \(file.lastPathComponent). Expected a Netscape-format export, the file every browser's Export Bookmarks command writes."
        }
    }

    private struct NonFileImportError: Error, CustomStringConvertible {
        let url: URL
        var description: String {
            "\(url.absoluteString) is not a file on this Mac. Bookmark exports are read from disk; nothing is fetched."
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
        importFailureMessage = nil   // Start over clears stale banners too
        phase = .idle
    }

    // MARK: - Run

    /// Classifies everything without a decision yet. Starting a fresh run and
    /// resuming a stopped one are the same operation, which is why there is one
    /// button rather than a size picker.
    func organize() async {
        guard isModelAvailable else { return }
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
        let url = URL.downloadsDirectory.appending(path: "rookmark-\(exportStem).organized.html")
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
