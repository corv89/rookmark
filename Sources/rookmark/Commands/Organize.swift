import ArgumentParser
import Foundation
import RookmarkKit

struct Organize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Classify bookmarks from an HTML export into topic folders."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: [.short, .customLong("output")], help: "Where to write the reorganized HTML. Defaults to <input>.organized.html")
    var output: String?

    @Flag(help: "Generate a fresh taxonomy, ignoring the export's existing folders.")
    var fresh = false

    @Flag(help: "Persist to SQLite and enable resume/undo (slower; for large libraries).")
    var stateful = false

    @Option(help: "Initial classification batch size (auto-shrinks on context overflow).")
    var batchSize: Int = 0

    @Option(name: .customLong("confidence-floor"), help: "Minimum confidence (0-100) to accept a classification. Items below this are routed to Unsorted. Set to 0 to disable.")
    var confidenceFloor: Int = 15

    @Flag(help: "Enable Phase 2 clustering to propose new folders for unsorted bookmarks.")
    var cluster = false

    @Option(name: .customLong("max-new-folders"), help: "Maximum number of new folders to propose during clustering.")
    var maxNewFolders: Int = 12

    @Option(help: "Taxonomy mode: 'preserve', 'fresh', or 'cluster'.")
    var taxonomy: String = "preserve"

    @Option(name: .customLong("embedder"), help: "Embedding backend: 'contextual' (default, multilingual, transformer) or 'sentence' (fast, English-only).")
    var embedder: String = "contextual"

    @Option(name: .customLong("cluster-threshold"), help: "Cosine similarity threshold (0-1) for grouping bookmarks into clusters. Use -1 for auto (per-embedder defaults).")
    var clusterThreshold: Double = -1

    @Option(name: .customLong("merge-threshold"), help: "Cosine similarity threshold (0-1) for merging proposed folder names with existing ones. Use -1 for auto (per-embedder defaults).")
    var mergeThreshold: Double = -1

    @Option(name: .customLong("folder-language"), help: "BCP-47 language code for generated folder names (e.g. 'en', 'fr'). Default: system preferred language.")
    var folderLanguage: String?

    @Option(name: .customLong("reuse-taxonomy"), help: "Reuse the taxonomy from a previous run (by run ID). Requires --stateful or a .db file next to the input.")
    var reuseTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file (format: {\"v\":2,\"folders\":[...]}).")
    var taxonomyFrom: String?

    @Flag(name: .customLong("no-enrich"), help: "Skip content enrichment (meta description fetching).")
    var noEnrich = false

    @Flag(name: .customLong("refresh-enrichments"), help: "Re-fetch meta descriptions even if cached.")
    var refreshEnrichments = false

    func run() async throws {
        let factory = SessionFactory()
        guard case .available = factory.availability() else {
            if case let .unavailable(reason) = factory.availability() {
                throw ValidationError(reason)
            }
            return
        }

        let taxMode: TaxonomyBuilder.Mode = {
            switch taxonomy {
            case "fresh": return .fresh
            default: return .preserve
            }
        }()
        var embedderPref: EmbedderFactory.Preference = {
            switch embedder {
            case "sentence": return .sentence
            default: return .contextual
            }
        }()

        if embedderPref == .contextual && !EmbedderFactory.hasContextualAssets() {
            FileHandle.standardError.write(Data(
                "Contextual embedding model not downloaded. Download now? (Y/N) [~500MB] ".utf8
            ))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if answer == "y" || answer == "yes" {
                FileHandle.standardError.write(Data("Downloading contextual model…\n".utf8))
                let success = await withCheckedContinuation { continuation in
                    EmbedderFactory.requestContextualAssets { ok in
                        continuation.resume(returning: ok)
                    }
                }
                if !success {
                    FileHandle.standardError.write(Data(
                        "warning: contextual model download failed; falling back to sentence embeddings\n".utf8
                    ))
                    embedderPref = .sentence
                }
            } else {
                FileHandle.standardError.write(Data(
                    "warning: contextual model not available; falling back to sentence embeddings\n".utf8
                ))
                embedderPref = .sentence
            }
        }

        let clusteringConfig = ClusteringConfig(
            enabled: cluster,
            similarityThreshold: clusterThreshold,
            mergeThreshold: mergeThreshold,
            maxNewFolders: maxNewFolders,
            folderLanguage: folderLanguage
        )
        let html = try String(contentsOfFile: input, encoding: .utf8)

        var pinned: Taxonomy?
        if let runID = reuseTaxonomy {
            guard !fresh else {
                throw ValidationError("--reuse-taxonomy and --fresh are mutually exclusive.")
            }
            let dbPath = input + ".db"
            let store = try Store(path: dbPath)
            guard let t = try store.loadTaxonomy(runID: runID) else {
                throw ValidationError("No taxonomy found for run #\(runID).")
            }
            if t.folders.contains(where: { $0.rationale.isEmpty }) {
                FileHandle.standardError.write(Data("warning: pinned taxonomy predates rationale storage; classification quality may be lower\n".utf8))
            }
            pinned = t
        } else if let path = taxonomyFrom {
            guard !fresh else {
                throw ValidationError("--taxonomy-from and --fresh are mutually exclusive.")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let envelope = try JSONDecoder().decode(TaxonomyEnvelope.self, from: data)
            pinned = Taxonomy(folders: envelope.folders)
        }

        let organizer = Organizer()
        let opts = Organizer.Options(
            taxonomyMode: fresh ? .fresh : taxMode,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            stateful: stateful,
            sourcePath: input,
            clustering: clusteringConfig,
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned,
            enrich: !noEnrich,
            refreshEnrichments: refreshEnrichments
        )

        final class ProgressState: @unchecked Sendable {
            private let lock = NSLock()
            private var lastLine = ""
            func update(_ line: String) {
                lock.lock()
                defer { lock.unlock() }
                if line != lastLine {
                    FileHandle.standardError.write(Data((line + "\r").utf8))
                    lastLine = line
                }
            }
        }
        let state = ProgressState()
        let result: Organizer.Result
        do {
            result = try await organizer.organize(
                html: html,
                options: opts,
                enrichmentProgress: { done, total in
                    state.update("Enriching \(done)/\(total)…")
                },
                onDeadLink: { title, url, reason in
                    FileHandle.standardError.write(Data(
                        "\n⚠️  Dead link: \"\(title)\" - \(url) (\(reason))\n".utf8
                    ))
                },
                progress: { done, total in
                    state.update("Classifying \(done)/\(total)…")
                },
                onResume: { already, total in
                    FileHandle.standardError.write(Data(
                        "resuming: \(already)/\(total) already classified\n".utf8))
                }
            )
        } catch Organizer.Error.contextualEmbedderUnavailable {
            throw ValidationError("Contextual embedder not available. Run: rookmark doctor --download-assets")
        }

        let out = output ?? (input as NSString).deletingPathExtension + ".organized.html"
        let rendered = NetscapeBookmarkWriter().write(result.bookmarks)
        try rendered.write(toFile: out, atomically: true, encoding: .utf8)

        if !noEnrich {
            let deadCount = result.deadLinks.count
            if deadCount > 0 {
                FileHandle.standardError.write(Data(
                    "\n✅ Enriched \(result.bookmarks.count) bookmarks (\(deadCount) dead link\(deadCount == 1 ? "" : "s") detected)\n".utf8
                ))
            }
        }

        let placed = result.bookmarks.filter { ($0.assignedFolder ?? Taxonomy.unsorted) != Taxonomy.unsorted }.count
        print("\nSorted \(placed)/\(result.bookmarks.count) bookmarks into \(result.taxonomy.folders.count) folders.")
        print("Wrote \(out) — re-import it from your browser's Bookmark Manager.")

        let causes = result.unsortedCauses
        let unsortedTotal = result.bookmarks.count - placed
        if unsortedTotal > 0 {
            FileHandle.standardError.write(Data("""
            Unsorted breakdown: \(unsortedTotal) total
              model-chose-Unsorted: \(causes.modelChoseUnsorted)
              below-floor (conf < \(confidenceFloor)): \(causes.belowFloor)
              unmapped/backfilled: \(causes.unmapped)
            \n
            """.utf8))
        }
    }
}
