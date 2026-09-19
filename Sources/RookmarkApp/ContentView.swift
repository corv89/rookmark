import AppKit
import RookmarkKit
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: OrganizerModel
    @State private var exportedPath: String?
    @State private var settingsLinkFailed = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // The floor goes on the detail column, not the window root: a frame
            // wrapped around the whole hierarchy stops the toolbar's safe area
            // reaching the scroll views, which renders rows under the toolbar.
            detail.frame(minWidth: 620, minHeight: 420)
        }
        .toolbar { toolbarContent }
        .searchable(text: $model.search, prompt: "Search titles and URLs")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Apple Intelligence can be enabled while Rookmark is running;
            // availability is re-read, never latched.
            model.refreshModelAvailability()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            // Rejected while a run is going: returning false springs the drag back
            // rather than silently discarding work.
            guard !model.isBusy else { return false }
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else { return false }

            // Acceptance needs the resolved URL: html/htm is decided from the file
            // extension (OrganizerModel.isImportableFile), and only returning false
            // here springs a bad drag back. The completion handler is the single
            // place an import can start; the bounded synchronous wait below only
            // decides the return value. File URL data is already on the drag
            // pasteboard, so resolving is normally instant; on a timeout the drag is
            // accepted and the same gate in the completion still keeps a non-export
            // (folder, PDF, json) from ever reaching the model.
            let gate = DispatchSemaphore(value: 0)
            let resolved = Mutex<URL?>(nil)
            provider.loadObject(ofClass: URL.self) { url, _ in
                resolved.withLock { $0 = url }
                gate.signal()
                guard let url else { return }
                Task { @MainActor in
                    guard OrganizerModel.isImportableFile(url) else { return }
                    model.requestImport(from: url)
                }
            }
            let decided = gate.wait(timeout: .now() + 0.5) != .timedOut
            if let url = resolved.withLock({ $0 }) {
                return OrganizerModel.isImportableFile(url)
            }
            return !decided   // completed without a URL: reject; timed out: let the completion decide
        }
        .confirmationDialog(
            "Replace the run on screen?",
            isPresented: Binding(
                get: { model.pendingImport != nil },
                set: { if !$0 { model.cancelImport() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingImport
        ) { url in
            Button("Import \(url.lastPathComponent)", role: .destructive) { model.confirmImport() }
            Button("Cancel", role: .cancel) { model.cancelImport() }
        } message: { _ in
            Text("The run from \(model.sourceName) will be discarded. Export it first if you still want it.")
        }
        .confirmationDialog(
            "Replace the run on screen?",
            isPresented: Binding(
                get: { model.pendingOrionProfile },
                set: { if !$0 { model.cancelOrionProfile() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use the Orion profile", role: .destructive) { model.confirmOrionProfile() }
            Button("Cancel", role: .cancel) { model.cancelOrionProfile() }
        } message: {
            Text("The run from \(model.sourceName) will be discarded. Export it first if you still want it.")
        }
        .onChange(of: model.source) { _, _ in
            // The footer path belongs to the previous source's export. Cleared even
            // when a failed import rolls the source straight back: the label is
            // informational, never a promise.
            exportedPath = nil
        }
    }

    // MARK: - Toolbar
    //
    // Plain buttons: on macOS 26 the toolbar renders its own Liquid Glass behind
    // items, so styling them with .glass as well double-stacks the material.
    // ToolbarSpacer is what splits items into separate glass groups.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                chooseFile()
            } label: {
                Label("Import a bookmarks HTML file", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(model.isBusy)
            .help("Load any browser's bookmarks export (.html or .htm). The file is only read, never modified.")
        }

        ToolbarItem {
            // Hidden when the profile is missing or already loaded; the button would
            // otherwise be a dead control. defaultFavouritesURL is one stat call when
            // the profile exists, so evaluating it in the toolbar is cheap.
            if OrionImporter.defaultFavouritesURL() != nil, model.source != .orionProfile {
                Button {
                    model.requestOrionProfile()
                } label: {
                    Label("Use Orion profile", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.isBusy)
                .help("Go back to the bookmarks in the installed Orion profile, without relaunching.")
            }
        }

        ToolbarItem {
            Button {
                Task { await model.organize() }
            } label: {
                // Toolbar buttons default to icon-only on macOS, which left the
                // action unlabelled while the status text beside it shared the
                // same glass capsule and read as overflow from the button.
                Label(organizeTitle, systemImage: model.rows.isEmpty ? "wand.and.stars" : "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut(.return)
            .disabled(model.isBusy || model.remaining.isEmpty || !model.isModelAvailable)
            .help(model.remaining.isEmpty
                  ? "Every bookmark has a proposed folder."
                  : "Classify the \(model.remaining.count) bookmarks without a folder yet, about \(minutes(model.estimatedSeconds)).")
        }

        // Just the control. Adjacent toolbar items share one piece of glass, so
        // a progress bar and two counters here crowded into the action's own
        // pill; the sidebar callout carries the run's state instead.
        if model.isBusy {
            ToolbarItem {
                Button("Pause") { model.pause() }
                    .help("Stop after the current batch. Resume picks up where it left off.")
            }
        }

        ToolbarSpacer(.flexible)

        if !model.rows.isEmpty {
            ToolbarItem {
                // A Picker in a toolbar renders as an empty control; a Menu of
                // Toggles shows the current choice and the checkmark beside it.
                Menu {
                    ForEach(OrganizerModel.Sort.allCases) { option in
                        Toggle(option.rawValue, isOn: Binding(
                            get: { model.sort == option },
                            set: { _ in model.sort = option }
                        ))
                    }
                } label: {
                    Label(model.sort.rawValue, systemImage: "arrow.up.arrow.down")
                }
                .help("Sort order")
            }
            ToolbarItem {
                Button {
                    exportedPath = try? model.exportOrganized().path(percentEncoded: false)
                } label: {
                    Label("Export a copy", systemImage: "square.and.arrow.up")
                }
                .disabled(model.acceptedCount == 0)
                .help("Write a new bookmarks file. Your browser is never modified.")
            }
        }
    }

    private var organizeTitle: String {
        if case .paused = model.phase { return "Resume" }
        return model.rows.isEmpty ? "Organize" : "Continue"
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds))s" : "\(Int((seconds / 60).rounded())) min"
    }

    // MARK: - Sidebar
    //
    // The library counts are context for the folder list, not controls, so they
    // sit here instead of taking a full-width band across the top.

    private var sidebar: some View {
        List(selection: $model.selectedFolder) {
            if let summary = model.sourceSummary {
                // Counts are formatted explicitly so they agree with each other;
                // interpolating an Int into Text applies locale grouping while a
                // pre-built String does not, which had 1687 sitting above 1.685.
                Section {
                    LabeledContent("Source", value: model.sourceName)
                        .help(model.sourceName)   // full file name on hover if truncated
                    LabeledContent("Bookmarks", value: summary.bookmarkCount.formatted(.number))
                    if let orphaned = summary.orphanedFolderReferences {
                        LabeledContent("Without a folder") {
                            Text(orphaned, format: .number)
                                .foregroundStyle(orphaned > 0 ? .orange : .secondary)
                        }
                    }
                    LabeledContent("Taxonomy", value: "\(model.taxonomyFolderCount) folders")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if model.isBusy || (!model.rows.isEmpty && !model.remaining.isEmpty) {
                workCallout
            }

            if !model.rows.isEmpty {
                Section("Folders") {
                    // Tagged with the sentinel rather than nil: a List selection
                    // binding cannot carry nil, so a nil-tagged row is
                    // unselectable and there is no way back to the full list.
                    folderRow(name: "All", count: model.rows.count, tag: OrganizerModel.allFolders)
                    ForEach(model.folders) { folder in
                        folderRow(name: folder.name, count: folder.count, tag: folder.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
    }

    /// Owns the state of the work in both phases: what is left when idle, live
    /// progress while running. One place for it means the toolbar does not have
    /// to grow a progress bar and two counters the moment a run starts.
    ///
    /// Given the weight of the staleness banner rather than a quiet stat row,
    /// but tinted with the accent colour instead of orange: work pending is not
    /// a problem to be warned about.
    private var workCallout: some View {
        HStack(spacing: 10) {
            if case .classifying = model.phase {
                ProgressView().controlSize(.small)
            } else if case .finishing = model.phase {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "tray.full.fill").foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(calloutTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if case .classifying(let done, let total) = model.phase {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .controlSize(.small)
                    Text("~\(minutes(Double(total - done) * OrganizerModel.secondsPerBookmark)) left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .finishing = model.phase {
                    Text("grouping leftovers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("to classify · ~\(minutes(model.estimatedSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(.accentColor.opacity(0.22)), in: .rect(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var calloutTitle: String {
        switch model.phase {
        case .classifying(let done, let total):
            "\(done.formatted(.number)) of \(total.formatted(.number))"
        case .finishing:
            "Almost done"
        default:
            "\(model.remaining.count.formatted(.number)) left"
        }
    }

    private func folderRow(name: String, count: Int, tag: String) -> some View {
        HStack(spacing: 8) {
            if tag != OrganizerModel.allFolders {
                Circle()
                    .fill(name == Taxonomy.unsorted ? Color.secondary : folderTint(tag))
                    .frame(width: 8, height: 8)
            }
            Text(name).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .failed(let message):
            failureNotice(message)
        case .scanning:
            notice(scanningTitle, systemImage: "magnifyingglass")
        case .classifying where model.rows.isEmpty, .finishing where model.rows.isEmpty:
            working
        case .idle where model.source == nil:
            dropTarget
        case .idle where model.rows.isEmpty:
            if case .unavailable = model.modelAvailability {
                // Availability outranks the privacy blurb: Organize can't run,
                // so the first thing a blocked user reads is why.
                modelUnavailableNotice
            } else {
                notice(
                    "Nothing leaves this Mac. Classification runs against the on-device model, and your browser's bookmarks are never modified. Rookmark only ever writes a new file.",
                    systemImage: "lock.laptopcomputer"
                )
            }
        default:
            VStack(spacing: 0) {
                importFailureBanner
                availabilityBanner
                statusBanner
                resultsTable
                if model.selectedRow != nil { inspector }
                footer
            }
        }
    }

    private var scanningTitle: String {
        if case .file = model.source { return "Reading \(model.sourceName)…" }
        return "Reading the Orion profile…"
    }

    private func notice(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// A failed import while a run was on screen: the run survives, so the
    /// failure is a dismissible banner over the table, not a replacement for it.
    @ViewBuilder
    private var importFailureBanner: some View {
        if let message = model.importFailureMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                Text("Import failed: \(message)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK") { model.dismissImportFailure() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
            .padding(.bottom, 10)
            .frame(maxWidth: 720)
        }
    }

    /// Full-detail failure, reserved for failures with no run to protect (a
    /// launch scan or a first import). The way back lives here, not only in the
    /// toolbar, so a dead scan never dead-ends the app (T3 review, major 3).
    private func failureNotice(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Start over") { model.discardSession() }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Full-detail notice when nothing else is on screen. Same layout as
    /// `notice(_:systemImage:tint:)` plus the settings button it can't carry.
    private var modelUnavailableNotice: some View {
        let state = model.modelAvailability
        return VStack(spacing: 10) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 30))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                if case .unavailable(let reason, let fixable) = state {
                    Text(reason)
                    Text(fixable
                         ? "Rookmark classifies bookmarks with Apple's on-device model. Once it's ready, switch back to Rookmark and this notice clears by itself."
                         : "Rookmark depends on Apple Intelligence, so it cannot sort bookmarks on this Mac.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)

            if case .unavailable(_, true) = state {
                if settingsLinkFailed {
                    // Deep-link fallback; the reason already names the pane.
                    Text("System Settings ▸ Apple Intelligence & Siri")
                        .font(.callout.weight(.medium))
                } else {
                    Button("Open Apple Intelligence & Siri settings") {
                        openAppleIntelligenceSettings()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// No source loaded yet. The drop is the primary action; the button and the
    /// toolbar's Cmd+O are the keyboard-accessible equivalents.
    private var dropTarget: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 30))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Drag a bookmarks export here, or")
                Button("Choose a file…") { chooseFile() }
                    .buttonStyle(.glass)
            }
            .font(.title3.weight(.medium))

            Text("Any browser works: export your bookmarks as HTML and drop the file on this window. The file is only read, never modified.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 3) {
                Text("Where the export lives").font(.caption.weight(.medium))
                hint("Safari", "File ▸ Export Bookmarks")
                hint("Chrome, Edge, Brave", "Bookmark Manager ▸ Export bookmarks")
                hint("Firefox", "Manage Bookmarks ▸ Import and Backup ▸ Export Bookmarks to HTML")
                Text("Orion's profile is read automatically when it's installed.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460, alignment: .leading)

            if case .unavailable(let reason, _) = model.modelAvailability {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .background(
                    isDropTargeted ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 14)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func hint(_ browser: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(browser):").foregroundStyle(.primary)
            Text(path)
        }
    }

    /// Fallback for anyone without drag-and-drop. Accepts both spellings of the
    /// extension: UTType.html covers .html, and .htm is appended dynamically when
    /// the system maps it to a distinct type.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a bookmarks HTML file"
        panel.message = "Choose a bookmarks export in the Netscape HTML format."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.htmlTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.requestImport(from: url)
    }

    private static let htmlTypes: [UTType] = {
        var types: [UTType] = [.html]
        if let htm = UTType(filenameExtension: "htm"), htm != .html { types.append(htm) }
        return types
    }()

    /// Compact version when a table is on screen (restored or finished run):
    /// same information in the status-banner idiom, so review/export stay
    /// available — only Organize is gated.
    @ViewBuilder
    private var availabilityBanner: some View {
        if case .unavailable(let reason, let showsSettingsLink) = model.modelAvailability {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                Text(reason)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if showsSettingsLink && !settingsLinkFailed {
                    Button("Open Apple Intelligence & Siri settings") {
                        openAppleIntelligenceSettings()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
            .padding(.bottom, 10)
            .frame(maxWidth: 720)
        }
    }

    /// `open(_:)` returns false where the link doesn't resolve; the reason
    /// strings already name the path, so the fallback shows it as text.
    private func openAppleIntelligenceSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
              NSWorkspace.shared.open(url)
        else {
            settingsLinkFailed = true
            return
        }
    }

    private var working: some View {
        VStack(spacing: 12) {
            ProgressView()
            if case .classifying(let done, let total) = model.phase {
                Text("Classifying \(done) of \(total) on-device…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Grouping the leftovers and naming new folders…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Status banner

    /// Says plainly when what is on screen is partial or no longer matches the
    /// browser. A restored run looks identical to a finished one otherwise,
    /// which is how someone exports half a library believing it complete.
    @ViewBuilder
    private var statusBanner: some View {
        let stale = model.staleness
        let paused = { if case .paused = model.phase { return true } else { return false } }()

        if paused || stale != nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.small)
                Text(statusMessage(paused: paused, stale: stale))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if stale != nil {
                    Button("Discard") { model.discardSession() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Throw away this run and start over")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .capsule)
            .padding(.bottom, 10)
            .frame(maxWidth: 720)
        }
    }

    private func statusMessage(paused: Bool, stale: SessionStore.Staleness?) -> String {
        var parts: [String] = []

        if paused {
            parts.append("Paused with \(model.remaining.count.formatted(.number)) of \(model.allBookmarks.count.formatted(.number)) still to classify.")
        } else if let stale {
            let when = stale.savedAt.formatted(.relative(presentation: .named))
            if stale.isIncomplete {
                parts.append("Restored a run from \(when) that never finished: \(stale.unclassified.formatted(.number)) bookmarks have no folder yet.")
            } else {
                parts.append("Restored a run from \(when).")
            }
        }

        if let stale, stale.hasDrifted {
            var drift: [String] = []
            if stale.added > 0 { drift.append("\(stale.added.formatted(.number)) added") }
            if stale.removed > 0 { drift.append("\(stale.removed.formatted(.number)) removed") }
            parts.append("Your bookmarks changed since then: \(drift.joined(separator: ", ")).")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Table

    private var resultsTable: some View {
        List(model.visibleRows, selection: $model.selectedRowID) { row in
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { row.accepted },
                    set: { _ in model.toggleAccepted(row.id) }
                ))
                .labelsHidden()
                .help("Accept this placement and include it in the export")

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).lineLimit(1)
                    Text(row.url)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)

                Text(row.folder)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        row.isUnsorted ? Color.secondary.opacity(0.15) : folderTint(row.folder).opacity(0.18),
                        in: .capsule
                    )
                    .foregroundStyle(row.isUnsorted ? Color.secondary : folderTint(row.folder))

                ConfidenceBadge(value: row.confidence)
            }
            .padding(.vertical, 2)
            .opacity(row.accepted ? 1 : 0.45)
            .tag(row.id)
        }
        .listStyle(.inset)
        .frame(minHeight: 200)
    }

    // MARK: - Inspector: why this folder?

    @ViewBuilder
    private var inspector: some View {
        if let row = model.selectedRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(row.title).font(.headline).lineLimit(1)
                    Spacer()
                    Menu {
                        ForEach(model.folders) { folder in
                            Button(folder.name) { model.move(row.id, to: folder.name) }
                        }
                        Divider()
                        Button(Taxonomy.unsorted) { model.move(row.id, to: Taxonomy.unsorted) }
                    } label: {
                        Label("Move to", systemImage: "folder")
                    }
                    .frame(width: 130)

                    Button {
                        if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                }

                if row.isUnsorted, let choice = row.modelChoice {
                    Label(
                        "Model chose \(choice) at \(row.confidence), below the confidence floor, so it was left Unsorted.",
                        systemImage: "questionmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else if let rationale = model.rationale(for: row.folder), !rationale.isEmpty {
                    Text("**\(row.folder)**  \(rationale)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text("**\(model.acceptedCount)** of \(model.rows.count) accepted")
            if !model.newFolders.isEmpty {
                Text("new folders: \(model.newFolders.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let exportedPath {
                Label(exportedPath, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func folderTint(_ folder: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown, .cyan, .mint]
        var hash = 5381
        for byte in folder.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }
}

/// Confidence has to be readable at a glance down a long list, so it carries
/// both the number and a color weight rather than relying on either alone.
private struct ConfidenceBadge: View {
    let value: Int

    private var tint: Color {
        switch value {
        case ..<40: .red
        case ..<70: .orange
        default: .secondary
        }
    }

    var body: some View {
        Text("\(value)")
            .font(.caption.monospacedDigit().weight(value < 70 ? .semibold : .regular))
            .foregroundStyle(tint)
            .frame(width: 28, alignment: .trailing)
            .help("Model confidence")
    }
}
