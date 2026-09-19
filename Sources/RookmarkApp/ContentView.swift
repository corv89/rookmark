import AppKit
import RookmarkKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: OrganizerModel
    @State private var exportedPath: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            statusBanner
            Divider()
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rookmark")
                    .font(.largeTitle.weight(.semibold))
                Text("on-device bookmark organizer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let seconds = model.lastRunSeconds {
                    Text("\(seconds, format: .number.precision(.fractionLength(1)))s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = model.summary {
                HStack(spacing: 28) {
                    stat("\(summary.bookmarkCount)", "bookmarks in Orion")
                    stat("\(summary.orphanedFolderReferences)", "with no valid folder", tint: .orange)
                    stat("\(model.taxonomyFolderCount)", "folders in taxonomy")
                    if case .finished = model.phase {
                        stat("\(model.sortedCount)/\(model.rows.count)", "placed", tint: .green)
                    }
                }
                if summary.orphanedFolderReferences > 0, model.rows.isEmpty {
                    Text("A browser import brought the bookmarks across but dropped the folders they lived in. They are one flat pile.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
    }

    private var organizeTitle: String {
        if case .paused = model.phase { return "Resume" }
        return model.rows.isEmpty ? "Organize" : "Continue"
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 90
            ? "\(Int(seconds))s"
            : "\(Int((seconds / 60).rounded())) min"
    }

    /// Says plainly when what is on screen is partial or no longer matches the
    /// browser. A restored run looks identical to a finished one otherwise, which
    /// is how people end up exporting half a library believing it was complete.
    @ViewBuilder
    private var statusBanner: some View {
        let stale = model.staleness
        let paused = { if case .paused = model.phase { return true } else { return false } }()

        if paused || stale != nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(statusMessage(paused: paused, stale: stale))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if stale != nil {
                    Button("Discard") { model.discardSession() }
                        .help("Throw away this run and start over")
                }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
        }
    }

    private func statusMessage(paused: Bool, stale: SessionStore.Staleness?) -> String {
        var parts: [String] = []

        if paused {
            parts.append("Paused with \(model.remaining.count) of \(model.allBookmarks.count) still to classify.")
        } else if let stale {
            let when = stale.savedAt.formatted(.relative(presentation: .named))
            if stale.isIncomplete {
                parts.append("Restored a run from \(when) that never finished: \(stale.unclassified) bookmarks have no folder yet.")
            } else {
                parts.append("Restored a run from \(when).")
            }
        }

        if let stale, stale.hasDrifted {
            var drift: [String] = []
            if stale.added > 0 { drift.append("\(stale.added) added") }
            if stale.removed > 0 { drift.append("\(stale.removed) removed") }
            parts.append("Your bookmarks changed since then: \(drift.joined(separator: ", ")).")
        }

        return parts.joined(separator: " ")
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                Task { await model.organize() }
            } label: {
                Label(organizeTitle, systemImage: model.rows.isEmpty ? "wand.and.stars" : "play.fill")
            }
            .keyboardShortcut(.return)
            .disabled(model.isBusy || model.summary == nil || model.remaining.isEmpty)
            .help(model.remaining.isEmpty
                  ? "Every bookmark has a proposed folder."
                  : "Classify the \(model.remaining.count) bookmarks without a folder yet, about \(minutes(model.estimatedSeconds)).")

            if case .classifying(let done, let total) = model.phase {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 140)
                Text("\(done)/\(total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("~\(minutes(Double(total - done) * OrganizerModel.secondsPerBookmark)) left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Pause") { model.pause() }
                    .help("Stop after the current batch. Resume picks up where it left off.")
            } else if case .finishing = model.phase {
                ProgressView().controlSize(.small)
                Text("Grouping leftovers, naming new folders…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !model.remaining.isEmpty {
                Text("~\(minutes(model.estimatedSeconds))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !model.rows.isEmpty {
                Picker("", selection: $model.sort) {
                    ForEach(OrganizerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)

                TextField("Search", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .failed(let message):
            notice(message, systemImage: "exclamationmark.triangle", tint: .orange)
        case .scanning:
            notice("Reading the Orion profile…", systemImage: "magnifyingglass")
        // Once rows start streaming in, switch to the table and let it fill.
        case .classifying where model.rows.isEmpty, .finishing where model.rows.isEmpty:
            working
        case .idle where model.rows.isEmpty:
            notice(
                "Nothing leaves this Mac. Classification runs against the on-device model, and your browser's bookmarks are never modified. Rookmark only ever writes a new file.",
                systemImage: "lock.laptopcomputer"
            )
        default:
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(spacing: 0) {
                    resultsTable
                    if model.selectedRow != nil {
                        Divider()
                        inspector
                    }
                    Divider()
                    exportBar
                }
            }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedFolder) {
            Section("Folders") {
                folderRow(name: "All", count: model.rows.count, tag: nil as String?)
                ForEach(model.folders) { folder in
                    folderRow(name: folder.name, count: folder.count, tag: folder.name)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 220)
    }

    private func folderRow(name: String, count: Int, tag: String?) -> some View {
        HStack(spacing: 8) {
            if let tag {
                Circle()
                    .fill(name == Taxonomy.unsorted ? Color.secondary : folderTint(tag))
                    .frame(width: 8, height: 8)
            }
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    // MARK: - Table

    private var resultsTable: some View {
        List(model.visibleRows, selection: $model.selectedRowID) { row in
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { row.included },
                    set: { _ in model.toggleIncluded(row.id) }
                ))
                .labelsHidden()
                .help("Include in the exported file")

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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        row.isUnsorted ? Color.secondary.opacity(0.15) : folderTint(row.folder).opacity(0.18),
                        in: .capsule
                    )
                    .foregroundStyle(row.isUnsorted ? Color.secondary : folderTint(row.folder))

                ConfidenceBadge(value: row.confidence)

                HStack(spacing: 4) {
                    judgeButton(row, accepted: true, systemImage: "hand.thumbsup.fill", tint: .green)
                    judgeButton(row, accepted: false, systemImage: "hand.thumbsdown.fill", tint: .red)
                }
            }
            .padding(.vertical, 2)
            .tag(row.id)
        }
        .listStyle(.inset)
        .frame(minHeight: 200)
    }

    private func judgeButton(_ row: OrganizerModel.Row, accepted: Bool, systemImage: String, tint: Color) -> some View {
        Button {
            model.judge(row.id, accepted: accepted)
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(row.accepted == accepted ? tint : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .help(accepted ? "Good placement" : "Wrong placement")
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
            .background(.quaternary.opacity(0.25))
        }
    }

    // MARK: - Export

    private var exportBar: some View {
        HStack(spacing: 14) {
            Text("**\(model.includedCount)** of \(model.rows.count) included")
            if model.wasCancelled {
                Text("stopped early")
                    .foregroundStyle(.orange)
            }
            if !model.newFolders.isEmpty {
                Text("new folders: \(model.newFolders.joined(separator: ", "))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let judged = model.judged
            if judged.accepted + judged.rejected > 0 {
                Text("judged \(judged.accepted) good · \(judged.rejected) wrong")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let exportedPath {
                Text(exportedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Button("Export a copy…") {
                exportedPath = try? model.exportOrganized().path(percentEncoded: false)
            }
            .disabled(model.includedCount == 0)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
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
