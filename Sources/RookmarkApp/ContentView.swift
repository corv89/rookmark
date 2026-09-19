import AppKit
import RookmarkKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: OrganizerModel
    @State private var exportedPath: String?

    var body: some View {
        // Deliberately not NavigationSplitView with a native toolbar. That route
        // gives Liquid Glass for free, but the detail list rendered up underneath
        // the toolbar and safe-area insets stopped laying out, so the controls
        // live in the window and carry the glass themselves.
        VStack(spacing: 0) {
            controlBar
            statusBanner
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.organize() }
            } label: {
                Label(organizeTitle, systemImage: model.rows.isEmpty ? "wand.and.stars" : "play.fill")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.return)
            .disabled(model.isBusy || model.summary == nil || model.remaining.isEmpty)
            .help(model.remaining.isEmpty
                  ? "Every bookmark has a proposed folder."
                  : "Classify the \(model.remaining.count) bookmarks without a folder yet, about \(minutes(model.estimatedSeconds)).")

            if model.isBusy {
                runStatus
                Button("Pause") { model.pause() }
                    .buttonStyle(.glass)
                    .help("Stop after the current batch. Resume picks up where it left off.")
            } else if !model.remaining.isEmpty, !model.rows.isEmpty {
                // Pre-formatted, then interpolated as a String. Interpolating an
                // Int straight into Text goes through LocalizedStringKey, which
                // applied different grouping than .formatted did in the sidebar
                // and left 1.673 sitting next to 1,687.
                Text("\(model.remaining.count.formatted(.number)) left · ~\(minutes(model.estimatedSeconds))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !model.remaining.isEmpty {
                Text("~\(minutes(model.estimatedSeconds))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !model.rows.isEmpty {
                Picker(selection: $model.sort) {
                    ForEach(OrganizerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Sort order")

                TextField("Search", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)

                Button {
                    exportedPath = try? model.exportOrganized().path(percentEncoded: false)
                } label: {
                    Label("Export a copy", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .disabled(model.acceptedCount == 0)
                .help("Write a new bookmarks file. Your browser is never modified.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var runStatus: some View {
        switch model.phase {
        case .classifying(let done, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text("\(done.formatted(.number))/\(total.formatted(.number))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("~\(minutes(Double(total - done) * OrganizerModel.secondsPerBookmark))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Grouping leftovers…").font(.callout).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
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
            if let summary = model.summary {
                // Counts are formatted explicitly so they agree with each other;
                // interpolating an Int into Text applies locale grouping while a
                // pre-built String does not, which had 1687 sitting above 1.685.
                Section {
                    LabeledContent("Bookmarks", value: summary.bookmarkCount.formatted(.number))
                    LabeledContent("Without a folder") {
                        Text(summary.orphanedFolderReferences, format: .number)
                            .foregroundStyle(summary.orphanedFolderReferences > 0 ? .orange : .secondary)
                    }
                    LabeledContent("Taxonomy", value: "\(model.taxonomyFolderCount) folders")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
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
        .frame(width: 230)
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
            notice(message, systemImage: "exclamationmark.triangle", tint: .orange)
        case .scanning:
            notice("Reading the Orion profile…", systemImage: "magnifyingglass")
        case .classifying where model.rows.isEmpty, .finishing where model.rows.isEmpty:
            working
        case .idle where model.rows.isEmpty:
            notice(
                "Nothing leaves this Mac. Classification runs against the on-device model, and your browser's bookmarks are never modified. Rookmark only ever writes a new file.",
                systemImage: "lock.laptopcomputer"
            )
        default:
            VStack(spacing: 0) {
                resultsTable
                if model.selectedRow != nil { inspector }
                footer
            }
        }
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
