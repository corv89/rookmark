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
    @State private var isEditingFolders = false

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
            // Discarded: the semaphore + completion handler below own the outcome; the returned Progress has no consumer here.
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
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
        .confirmationDialog(
            "Start fresh?",
            isPresented: Binding(
                get: { model.pendingStartFresh },
                set: { if !$0 { model.cancelStartFresh() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Start fresh", role: .destructive) { model.confirmStartFresh() }
            Button("Cancel", role: .cancel) { model.cancelStartFresh() }
        } message: {
            Text("The run from \(model.sourceName) will be discarded and Rookmark will go back to the source picker. Export it first if you still want it.")
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
            // Also hidden with nothing loaded at all: the welcome grid has its own
            // Orion card right there, so a second one in the toolbar is noise.
            if OrionImporter.defaultFavouritesURL() != nil,
               model.source != nil, model.source != .orionProfile {
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
            // The way back to the welcome grid, and the only control that
            // unloads a source. Shown whenever anything is loaded — not gated
            // behind a failure or a stale restore, which is what left the app
            // reading as "Orion, and stuck" with no visible way to anything else.
            if model.source != nil {
                Button {
                    model.requestStartFresh()
                } label: {
                    Label("Switch source", systemImage: "rectangle.grid.2x2")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.isBusy)
                .help("Discard this run and go back to the list of browsers. Export it first if you want to keep it.")
            }
        }

        ToolbarItem {
            // Nothing loaded means nothing to organize, and the disabled button
            // read as a broken control on the welcome screen rather than an
            // action waiting for input.
            if model.source != nil {
                Button {
                    Task { await model.organize() }
                } label: {
                    // Toolbar buttons default to icon-only on macOS, which left
                    // the action unlabelled while the status text beside it
                    // shared the same glass capsule and read as overflow from
                    // the button.
                    Label(organizeTitle, systemImage: model.rows.isEmpty ? "wand.and.stars" : "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.return)
                .disabled(model.isBusy || model.remaining.isEmpty || !model.isModelAvailable)
                .help(model.remaining.isEmpty
                      ? "Every bookmark has a proposed folder."
                      : "Classify the \(model.remaining.count) bookmarks without a folder yet, about \(minutes(model.estimatedSeconds)).")
            }
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
        // macOS 27 logged "reentrant operation in its NSTableView delegate" once
        // per launch. Hypothesis: the sidebar List installs while model.rows is
        // still empty (the scan in RookmarkApp's .task cannot have finished), so
        // the only row carrying the "All" sentinel tag — rendered under
        // `if !model.rows.isEmpty` — does not exist, yet selectedFolder already
        // holds that sentinel: the table starts with a selection id matching no
        // installed row, and restoreSession()'s row writes land around it. This
        // wrapper keeps the value the table sees consistent with the rows it has
        // installed: nil while there is nothing to select (visibleRows treats nil
        // and the sentinel identically, so filtering is unchanged), the model
        // value otherwise — the All row is selected the moment rows exist, exactly
        // as before. The sentinel design and restoreSession() are untouched.
        // Revert: restore `$model.selectedFolder` if the warning survives this.
        List(selection: Binding(
            get: { model.rows.isEmpty ? nil : model.selectedFolder },
            set: { model.selectedFolder = $0 }
        )) {
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
                    HStack {
                        LabeledContent("Taxonomy", value: "\(model.taxonomyFolderCount) folders")
                        Spacer()
                        Button("Edit folders…") { isEditingFolders = true }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(model.isBusy)
                            .help("Rename, add, delete, or merge folders. Applies to this run only; the bundled defaults are never modified.")
                    }
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
        .sheet(isPresented: $isEditingFolders) {
            TaxonomyEditorSheet(model: model)
        }
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
            // Start over, not Discard: a failure with nothing on screen should
            // land on the source picker, where another browser can be chosen —
            // discardSession() alone would keep the source that just failed.
            // Routed through the request so a failure that *does* have rows
            // (a run that died mid-classify) still gets the export-first warning.
            Button("Start over") { model.requestStartFresh() }
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

    /// No source loaded yet. One card per browser is the primary affordance:
    /// the previous single "Choose a file…" button carried a paragraph of hints
    /// covering every browser at once, which meant the answer to "how do I get
    /// my Chrome bookmarks in" was buried in prose rather than being a thing to
    /// click. Drag-and-drop is unchanged and still lands anywhere on the window;
    /// it is named here as the secondary path, not the only one.
    private var dropTarget: some View {
        // The dashed panel is sized to its content and centred, rather than
        // stretched to the whole detail column: filling the column left the
        // cards pinned to the top of an otherwise empty rectangle several times
        // their height. GeometryReader + a minHeight is what centres it while
        // still letting it scroll if the window is shorter than the content.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 5) {
                        Text("Where are your bookmarks?")
                            .font(.title2.weight(.semibold))
                        Text("Pick a browser. Rookmark only ever reads — your browser is never modified.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    // A fixed column count, chosen from the number of cards, so
                    // the last row is never short. The count varies with what
                    // is installed, so this cannot be a constant.
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .flexible(minimum: 118, maximum: Self.cardMaxWidth),
                                spacing: Self.cardSpacing
                            ),
                            count: columnCount
                        ),
                        spacing: Self.cardSpacing
                    ) {
                        ForEach(installedSources) { browser in
                            sourceCard(browser)
                        }
                        otherFileCard
                    }
                    .frame(width: gridWidth)

                    VStack(spacing: 6) {
                        Label(
                            "Only browsers installed on this Mac are listed. Anything else works through Other browser.",
                            systemImage: "macwindow"
                        )
                        Label(
                            "Or drag a bookmarks export onto this window.",
                            systemImage: "arrow.down.doc"
                        )
                        Label(
                            "Nothing leaves this Mac: classification runs against the on-device model, and Rookmark only ever writes a new file.",
                            systemImage: "lock.laptopcomputer"
                        )
                        if case .unavailable(let reason, _) = model.modelAvailability {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                }
                // The width is the content's own plus the inset, not clamped to
                // the content: a frame at exactly `gridWidth` squeezes the side
                // padding back out again, because the grid inside is a fixed
                // width and wins. That left the card row flush against the
                // dashes while top and bottom kept their margins.
                .padding(.horizontal, Self.panelInset)
                .padding(.vertical, 24)
                .frame(width: panelWidth)
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
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
        }
    }

    // MARK: welcome grid layout
    //
    // The card count is whatever is installed, so the grid geometry is derived
    // rather than constant: a fixed four columns would strand a short last row
    // on most machines.

    private static let cardMaxWidth: CGFloat = 186
    private static let cardSpacing: CGFloat = 10
    /// Side margin between the cards and the dashed border, sized to read as
    /// balanced against the vertical padding above the heading and below the
    /// privacy note. Derived from the grid rather than fixed to a card count,
    /// so it holds whatever `columnCount` picks on a given Mac.
    private static let panelInset: CGFloat = 30

    /// Only the browsers this Mac actually has, plus the catch-all. A browser
    /// Rookmark cannot draw the real icon for is not shown at all: an SF Symbol
    /// standing in for a company's logo never reads as that company, so the
    /// card would be claiming to be something it isn't. Whatever is left out
    /// is still importable through "Other browser", which needs no logo to be
    /// honest about what it does.
    private var installedSources: [BrowserSource] {
        BrowserSource.all.filter(\.isInstalled)
    }

    /// Including the catch-all card, which is always last.
    private var cardCount: Int { installedSources.count + 1 }

    /// The largest count up to four that divides the cards evenly, so the last
    /// row is full. A small count goes on one row; a count with no such divisor
    /// (seven cards — six browsers plus the catch-all) falls back to four and
    /// accepts one short row, which beats a row of seven slivers.
    private var columnCount: Int {
        if cardCount <= 5 { return max(cardCount, 1) }
        for candidate in stride(from: 4, through: 2, by: -1) where cardCount % candidate == 0 {
            return candidate
        }
        return 4
    }

    /// Pinned rather than left to fill: flexible columns with no width cap
    /// stretch two or three cards across the whole panel.
    private var gridWidth: CGFloat {
        let columns = CGFloat(columnCount)
        return columns * Self.cardMaxWidth + (columns - 1) * Self.cardSpacing
    }

    /// The dashed panel: whatever the widest child needs, plus a side margin on
    /// each edge. The floor keeps the explanatory lines from being forced into
    /// a narrow column when only two or three cards are on screen.
    private var panelWidth: CGFloat {
        max(gridWidth, 440) + Self.panelInset * 2
    }

    /// One browser. Orion's card runs the real importer when the profile is
    /// installed; every other browser has no native importer, so the card opens
    /// the panel already carrying that browser's own export path — the
    /// instruction arrives with the file chooser rather than in a wall of hints
    /// the user has to match to their browser themselves.
    private func sourceCard(_ browser: BrowserSource) -> some View {
        let live = browser.readsProfileDirectly && OrionImporter.defaultFavouritesURL() != nil
        return Button {
            if live {
                // Safe from here: with no source loaded the guard in
                // requestOrionProfile falls straight through to the load.
                model.requestOrionProfile()
            } else {
                chooseFile(for: browser)
            }
        } label: {
            cardLabel(
                icon: browser.icon,
                title: browser.name,
                caption: live ? "Read automatically" : browser.shortExportPath,
                // Only consulted by the symbol fallback, which a browser card
                // reaches solely in the profile-outlived-the-app case.
                tint: .accentColor
            )
        }
        .buttonStyle(SourceCardStyle())
        .disabled(model.isBusy)
        .help(live
              ? "Read the bookmarks in the installed Orion profile. Nothing to export."
              : "In \(browser.name): \(browser.exportPath). Then choose the file it wrote.")
    }

    /// The catch-all, kept because the grid can only name the browsers we know
    /// about: any Netscape-format export works, whatever wrote it.
    private var otherFileCard: some View {
        Button {
            chooseFile(for: nil)
        } label: {
            cardLabel(
                icon: .symbol("square.and.arrow.down"),
                title: "Other browser",
                caption: "Choose an HTML export",
                tint: .secondary
            )
        }
        .buttonStyle(SourceCardStyle())
        .disabled(model.isBusy)
        // No Cmd+O here: the toolbar's import button already owns it, and two
        // live views claiming the same shortcut makes which one fires arbitrary.
        .help("Any browser's bookmarks export in the Netscape HTML format (.html or .htm).")
    }

    private func cardLabel(icon: BrowserSource.Icon, title: String, caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The icon box lives inside Icon.view so the two cases cannot
            // diverge: a frame applied here and not there is exactly what left
            // the real-icon cards sitting differently from the symbol ones.
            icon.view(tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Opens the panel for one browser, or for no browser in particular. The
    /// import itself is the same call either way — `browser` only decides what
    /// the panel says, which is the whole point: the export step is browser
    /// specific and the file format is not.
    private func chooseFile(for browser: BrowserSource?) {
        let panel = NSOpenPanel()
        if let browser {
            panel.title = "Import \(browser.name) bookmarks"
            panel.message = "In \(browser.name): \(browser.exportPath). Then choose the HTML file it wrote."
        } else {
            panel.title = "Import a bookmarks HTML file"
            panel.message = "Choose a bookmarks export in the Netscape HTML format."
        }
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.htmlTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.requestImport(from: url)
    }

    /// Kept for the toolbar's Cmd+O equivalent, which belongs to no browser.
    private func chooseFile() { chooseFile(for: nil) }

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

// MARK: - Welcome grid

/// One browser on the welcome grid.
///
/// Only Orion has a native importer (`OrionImporter` reads its profile
/// directly); every other browser reaches Rookmark as an HTML export, so what
/// distinguishes these entries is almost entirely *where that browser hides its
/// Export Bookmarks command*. That string is the payload — shown on the card,
/// repeated in the open panel, and in the tooltip in full.
private struct BrowserSource: Identifiable {
    /// The bundle id, which doubles as the lookup key for the installed app's
    /// real icon.
    let id: String
    let name: String
    /// The full path through that browser's menus, for the panel and tooltip.
    let exportPath: String
    /// The same instruction trimmed to fit a card. Firefox's real path is three
    /// menus deep and does not fit anywhere sensible at card width.
    let shortExportPath: String
    /// Orion only: there is a live importer, so this card skips the export step.
    var readsProfileDirectly = false

    /// Orion leads because it is the one source that needs no export at all.
    /// The rest are in rough order of how many Macs have them. Being in this
    /// list is not enough to appear on screen — see `isInstalled`.
    static let all: [BrowserSource] = [
        BrowserSource(
            id: "com.kagi.kagimacOS", name: "Orion",
            // The export path still has to be right: `readsProfileDirectly`
            // only wins when a profile is actually installed, and on a Mac
            // without Orion this card is an ordinary export card.
            exportPath: "File ▸ Export ▸ Bookmarks",
            shortExportPath: "File ▸ Export Bookmarks",
            readsProfileDirectly: true
        ),
        BrowserSource(
            id: "com.apple.Safari", name: "Safari",
            exportPath: "File ▸ Export ▸ Bookmarks",
            shortExportPath: "File ▸ Export Bookmarks"
        ),
        BrowserSource(
            id: "com.google.Chrome", name: "Chrome",
            exportPath: "Bookmarks ▸ Bookmark Manager ▸ ⋮ ▸ Export bookmarks",
            shortExportPath: "Bookmark Manager ▸ Export"
        ),
        BrowserSource(
            id: "org.mozilla.firefox", name: "Firefox",
            exportPath: "Bookmarks ▸ Manage Bookmarks ▸ Import and Backup ▸ Export Bookmarks to HTML",
            // Truncated at card width when it carried "to HTML" as well; the
            // full three-menu path is in the tooltip and the open panel.
            shortExportPath: "Manage Bookmarks ▸ Export"
        ),
        BrowserSource(
            id: "com.brave.Browser", name: "Brave",
            exportPath: "Bookmarks ▸ Bookmark Manager ▸ ⋮ ▸ Export bookmarks",
            shortExportPath: "Bookmark Manager ▸ Export"
        ),
        BrowserSource(
            id: "com.microsoft.edgemac", name: "Edge",
            exportPath: "Favourites ▸ Manage favourites ▸ ⋯ ▸ Export favourites",
            shortExportPath: "Manage favourites ▸ Export"
        ),
        BrowserSource(
            id: "com.vivaldi.Vivaldi", name: "Vivaldi",
            exportPath: "File ▸ Export Bookmarks",
            shortExportPath: "File ▸ Export Bookmarks"
        ),
    ]

    /// Whether this browser earns a card. The test is the real icon, not a
    /// hand-kept list of install locations: LaunchServices already knows where
    /// apps are (it covers /Applications, ~/Applications and everywhere else
    /// an app can legitimately live, and stays in sync with Spotlight), and
    /// having the icon is exactly the condition for drawing an honest card.
    @MainActor
    var isInstalled: Bool {
        if BrowserIconCache.icon(for: id) != nil { return true }
        // One exception: a profile can outlive the app it belongs to, and the
        // live importer still reads it. Hiding a source that actually loads
        // would be worse than the generic icon this falls back to.
        return readsProfileDirectly && OrionImporter.defaultFavouritesURL() != nil
    }

    @MainActor
    var icon: Icon {
        // The fallback is reachable only through the profile-outlived-the-app
        // case above: every other card is gated on the real icon existing, so
        // no symbol ever stands in for a company's logo. That substitution is
        // what made the grid look wrong — a green ring is not Chrome's mark,
        // and no SF Symbol ever will be.
        BrowserIconCache.icon(for: id).map(Icon.app) ?? .symbol("bookmark.fill")
    }

    /// The installed app's own icon — the thing the user already recognizes in
    /// their Dock — or, for the two cards that stand for no particular brand
    /// ("Other browser", and a profile whose app is gone), a symbol.
    enum Icon {
        case app(NSImage)
        case symbol(String)

        /// Both cases end up in the same box, leading-aligned: the frame lives
        /// here, once, because applying it to one case and not the other is
        /// precisely what made real-icon cards sit differently from symbol ones.
        func view(tint: Color) -> some View {
            Group {
                switch self {
                case .app(let image):
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 21))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 26, height: 26, alignment: .leading)
        }
    }
}

/// LaunchServices lookups are cheap but not free, and a grid cell re-renders on
/// every hover; the answer cannot change while the app is running in any way
/// that matters, so it is resolved once per bundle id.
@MainActor
private enum BrowserIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
        cache[bundleID] = image
        return image
    }
}

/// The card idiom: Liquid Glass like the rest of the app, but shaped as a
/// rounded rect rather than the capsule `.glass` gives a normal button, and
/// tinted on hover so a grid of twenty-odd points of tappable area still tells
/// you which one you are on.
private struct SourceCardStyle: ButtonStyle {
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: 78)
            .contentShape(.rect(cornerRadius: 12))
            .glassEffect(
                .regular.tint(.accentColor.opacity(isHovering && isEnabled ? 0.28 : 0.10)),
                in: .rect(cornerRadius: 12)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// In-GUI editing of the run's folder list. Deliberately plain List/Form in a
/// sheet: rename, add, delete, merge — each a direct call on the model, which
/// validates and reports rejections as a one-line footnote rather than an
/// alert. Edits land in the working copy and the session snapshot; the
/// bundled taxonomy file is never written.
private struct TaxonomyEditorSheet: View {
    let model: OrganizerModel
    @Environment(\.dismiss) private var dismiss

    @State private var renameTarget: String?
    @State private var renameDraft = ""
    @State private var renameRationaleDraft = ""
    @State private var addName = ""
    @State private var addRationale = ""
    @State private var isAdding = false
    @State private var deleteTarget: String?
    @State private var editError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.workingFolders, id: \.name) { folder in
                        folderRow(folder)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.isTaxonomyOversized {
                            // Warned, never blocked: the kit prunes at its own
                            // runtime ceiling regardless.
                            Label(
                                "\(model.workingFolders.count) folders ride along in every classification batch — a list this long shrinks the batch and slows the run.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                        Text("Unsorted always exists and cannot be renamed or deleted; deleted folders' bookmarks go there.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                errorFootnote
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            .navigationTitle("Edit Folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Folder") {
                        addName = ""
                        addRationale = ""
                        editError = nil
                        isAdding = true
                    }
                }
            }
            .frame(minWidth: 380, minHeight: 340)
            .sheet(isPresented: $isAdding) { addSheet }
            .sheet(isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { closeRename() } }
            )) {
                renameSheet
            }
            .confirmationDialog(
                deleteTarget.map { "Delete “\($0)”?" } ?? "Delete folder?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Folder", role: .destructive) {
                    if let target = deleteTarget {
                        perform { try model.deleteFolder(target) }
                    }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                // The consequence, spelled out before the irreversible act.
                Text("\(count(of: deleteTarget ?? "")) bookmark(s) will move to \(Taxonomy.unsorted).")
            }
        }
    }

    private func folderRow(_ folder: Taxonomy.Folder) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if !folder.rationale.isEmpty {
                    Text(folder.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text("\(count(of: folder.name))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("\(count(of: folder.name)) bookmarks filed here")
            Menu {
                Button("Rename…") { openRename(folder) }
                Menu("Merge into") {
                    ForEach(model.workingFolders.filter { $0.name != folder.name }, id: \.name) { other in
                        Button(other.name) {
                            perform { try model.mergeFolder(folder.name, into: other.name) }
                        }
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { deleteTarget = folder.name }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Rename, merge, or delete this folder")
        }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $addName)
                    TextField("Rationale (optional)", text: $addRationale)
                } footer: {
                    errorFootnote
                }
            }
            .navigationTitle("Add Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isAdding = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        perform { try model.addFolder(named: addName, rationale: addRationale) }
                        if editError == nil { isAdding = false }
                    }
                    .disabled(addName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(minWidth: 320)
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $renameDraft)
                    TextField("Rationale", text: $renameRationaleDraft)
                } footer: {
                    errorFootnote
                }
            }
            .navigationTitle("Edit Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { closeRename() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let target = renameTarget else { return }
                        perform {
                            try model.updateFolder(target, to: renameDraft, rationale: renameRationaleDraft)
                        }
                        if editError == nil { closeRename() }
                    }
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(minWidth: 320)
        }
    }

    private func openRename(_ folder: Taxonomy.Folder) {
        renameTarget = folder.name
        renameDraft = folder.name
        renameRationaleDraft = folder.rationale
        editError = nil
    }

    private func closeRename() {
        renameTarget = nil
        renameDraft = ""
        renameRationaleDraft = ""
    }

    private func count(of name: String) -> Int {
        model.rows.filter { $0.folder == name }.count
    }

    /// Runs one model edit, turning a rejection into the sheet's red footnote.
    /// A passed edit clears any previous failure.
    private func perform(_ edit: () throws -> Void) {
        do {
            editError = nil
            try edit()
        } catch {
            editError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    @ViewBuilder
    private var errorFootnote: some View {
        if let editError {
            Text(editError)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
