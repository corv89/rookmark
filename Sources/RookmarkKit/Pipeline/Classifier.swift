import Foundation
import FoundationModels

/// Phase 3 of the pipeline: assign each bookmark to a taxonomy folder using the
/// on-device model, one short batch at a time.
///
/// Design rules driven by the (OS-dependent) context window and the shared model resource:
///  • A fresh `LanguageModelSession` per batch — never accumulate transcript.
///  • Short, token-budgeted batches; shrink-and-retry on context overflow.
///  • Refusals are an expected per-item outcome → isolate, then route to Unsorted.
///  • Up to 4 batches in flight at once (sliding-window TaskGroup) — measured
///    ~10% wall-clock win at maxConcurrency=4 on a 200-item corpus with no
///    significant precision/yield cost (2026-09-20 sweep); see TODO.txt item 2.
public actor Classifier {

    public struct Config: Sendable {
        /// `0` derives the starting size from the live context window instead of
        /// fixing it. The taxonomy block is re-sent with every batch, so how many
        /// items fit depends on both the window and the taxonomy — and the window
        /// is not a constant across OS versions (4 096 on some, 8 192 on others).
        /// Set a positive value to pin it, which is what the eval sweeps do.
        public var initialBatchSize: Int
        public var minBatchSize: Int
        public var confidenceFloor: Int
        public var maxConcurrency: Int

        public init(
            initialBatchSize: Int = 0,
            minBatchSize: Int = 1,
            confidenceFloor: Int = 15,
            maxConcurrency: Int = 4
        ) {
            self.initialBatchSize = initialBatchSize
            self.minBatchSize = minBatchSize
            self.confidenceFloor = confidenceFloor
            self.maxConcurrency = maxConcurrency
        }
    }

    public struct Decision: Sendable, Equatable {
        public var bookmarkID: String
        public var folder: String
        public var confidence: Int
        public var modelChosenFolder: String?

        public init(bookmarkID: String, folder: String, confidence: Int, modelChosenFolder: String? = nil) {
            self.bookmarkID = bookmarkID
            self.folder = folder
            self.confidence = confidence
            self.modelChosenFolder = modelChosenFolder
        }
    }

    /// Reports per-batch progress (committed count, total). Hook the CLI bar here.
    public typealias ProgressHandler = @Sendable (_ done: Int, _ total: Int) -> Void

    /// Delivers each batch's decisions as soon as it lands, so a UI can fill in
    /// while the run continues rather than waiting minutes for the whole array.
    /// Note these are not final: Phase 2 clustering may later re-place anything
    /// that came back `Unsorted`, so consumers must key by `bookmarkID` and
    /// update in place.
    public typealias BatchHandler = @Sendable (_ decisions: [Decision]) -> Void

    /// Ceiling for the derived batch size. Bigger batches amortize the taxonomy
    /// block better, but every item's answer has to fit the output reserve too,
    /// and large batches make the model likelier to skip items.
    static let autoBatchCap = 12

    /// Counts of why bookmarks ended up in Unsorted.
    public struct UnsortedCauses: Sendable, Equatable {
        public var modelChoseUnsorted: Int = 0
        public var belowFloor: Int = 0
        public var unmapped: Int = 0

        public var total: Int { modelChoseUnsorted + belowFloor + unmapped }
    }

    private let factory: SessionFactory
    private let config: Config
    private let budget: TokenBudget
    private let schema: GenerationSchema?
    public private(set) var refusalCount: Int = 0
    public private(set) var unsortedCauses: UnsortedCauses = UnsortedCauses()

    public init(factory: SessionFactory, config: Config, budget: TokenBudget, taxonomy: Taxonomy? = nil) {
        self.factory = factory
        self.config = config
        self.budget = budget
        if let t = taxonomy {
            self.schema = try? ConstrainedClassificationSchema.make(allowedFolders: t.allowedFolderNames)
        } else {
            self.schema = nil
        }
    }

    private static let instructions = """
    You sort web bookmarks into folders. You are given a list of allowed folders \
    (name: description) and a list of items, each as `id | title | url` and \
    optionally `| description` (a meta description of the page content). \
    For every item, choose the single best-fitting folder from the allowed list. \
    Focus on what the page is actually about based on its title, URL path, and \
    description (when available), not just the domain name. For example, a \
    Wikipedia article about electric vehicles belongs in the EV folder, not \
    Search & Reference. Use the description to disambiguate when the title and \
    URL are ambiguous. \
    If none fits well, choose "Unsorted". Return exactly one assignment per item \
    and echo each id exactly. Do not invent folders.
    """

    /// Classifies all bookmarks against `taxonomy`. Pure: returns decisions; the
    /// caller persists/commits (enables resume + undo).
    /// Throws `CancellationError` if the surrounding task is cancelled. Decisions
    /// already delivered through `onBatch` remain valid — the caller keeps them.
    public func classify(
        _ bookmarks: [Bookmark],
        taxonomy: Taxonomy,
        enrichments: [String: ContentEnricher.EnrichResult]? = nil,
        progress: ProgressHandler? = nil,
        onBatch: BatchHandler? = nil
    ) async throws -> [Decision] {
        let allowed = Set(taxonomy.allowedFolderNames.map(Self.canonical))
        let folderBlock = Self.renderFolders(taxonomy)
        let ceiling = derivedInitialBatchSize(bookmarks, folderBlock: folderBlock, enrichments: enrichments)

        if config.maxConcurrency > 1 {
            return try await classifyConcurrently(
                bookmarks, taxonomy: taxonomy, folderBlock: folderBlock, allowed: allowed,
                enrichments: enrichments, chunkSize: ceiling, progress: progress, onBatch: onBatch
            )
        }

        var decisions: [Decision] = []
        decisions.reserveCapacity(bookmarks.count)
        var index = 0
        var batchSize = ceiling

        /// Records a finished slice and publishes it before the next model call.
        func commit(_ batch: [Decision], through end: Int) {
            decisions.append(contentsOf: batch)
            index = end
            onBatch?(batch)
            progress?(decisions.count, bookmarks.count)
        }

        while index < bookmarks.count {
            // Cancellation must be observed here rather than left to the catch-all
            // below, which would otherwise file the remaining items under Unsorted
            // and report a successful run.
            try Task.checkCancellation()

            let end = min(index + batchSize, bookmarks.count)
            let slice = Array(bookmarks[index..<end])

            do {
                let batch = try await classifyBatch(slice, folderBlock: folderBlock,
                                                     allowed: allowed, taxonomy: taxonomy,
                                                     enrichments: enrichments)
                commit(batch, through: end)
                // Recover toward the ceiling after a successful batch.
                batchSize = min(ceiling, batchSize + 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch let err as ClassifierError {
                switch err {
                case .contextOverflow where batchSize > config.minBatchSize:
                    batchSize = max(config.minBatchSize, batchSize / 2)   // shrink + retry
                case .refused where slice.count > 1:
                    batchSize = config.minBatchSize                        // isolate the culprit
                default:
                    // Single item still failing → park it in Unsorted, move on.
                    commit(slice.map {
                        Decision(bookmarkID: $0.id, folder: Taxonomy.unsorted, confidence: 0)
                    }, through: end)
                    unsortedCauses.unmapped += slice.count
                }
            } catch {
                // A cancelled URLSession/model call can surface as something other
                // than CancellationError; never swallow it into Unsorted.
                if Task.isCancelled { throw CancellationError() }
                commit(slice.map {
                    Decision(bookmarkID: $0.id, folder: Taxonomy.unsorted, confidence: 0)
                }, through: end)
                unsortedCauses.unmapped += slice.count
            }
        }
        return decisions
    }

    // MARK: - Concurrent path (maxConcurrency > 1)

    /// Sliding-window TaskGroup: up to `config.maxConcurrency` chunks in flight
    /// at once, each a fixed size (no cross-chunk adaptive resizing, since chunks
    /// run out of order and can't share a running `batchSize` heuristic). Overflow
    /// and refusal are handled per-chunk by `classifySliceRobust`. Order of the
    /// returned decisions is unspecified — callers key by `bookmarkID` (see
    /// `BatchHandler`), and `Organizer` already does.
    private func classifyConcurrently(
        _ bookmarks: [Bookmark],
        taxonomy: Taxonomy,
        folderBlock: String,
        allowed: Set<String>,
        enrichments: [String: ContentEnricher.EnrichResult]?,
        chunkSize: Int,
        progress: ProgressHandler?,
        onBatch: BatchHandler?
    ) async throws -> [Decision] {
        let size = max(1, chunkSize)
        let chunks: [[Bookmark]] = stride(from: 0, to: bookmarks.count, by: size).map {
            Array(bookmarks[$0..<min($0 + size, bookmarks.count)])
        }

        var decisions: [Decision] = []
        decisions.reserveCapacity(bookmarks.count)
        var done = 0

        try await withThrowingTaskGroup(of: [Decision].self) { group in
            var nextChunk = 0
            let window = min(config.maxConcurrency, chunks.count)

            func launchNext() {
                guard nextChunk < chunks.count else { return }
                let chunk = chunks[nextChunk]
                nextChunk += 1
                group.addTask {
                    try await self.classifySliceRobust(
                        chunk, folderBlock: folderBlock, allowed: allowed,
                        taxonomy: taxonomy, enrichments: enrichments
                    )
                }
            }

            for _ in 0..<window { launchNext() }

            while let batch = try await group.next() {
                try Task.checkCancellation()
                decisions.append(contentsOf: batch)
                done += batch.count
                onBatch?(batch)
                progress?(done, bookmarks.count)
                launchNext()
            }
        }

        return decisions
    }

    /// Classifies one fixed-size slice, handling overflow/refusal locally by
    /// splitting — mirrors the sequential loop's shrink/isolate behavior but
    /// self-contained per slice, since concurrent chunks share no mutable state.
    private func classifySliceRobust(
        _ slice: [Bookmark],
        folderBlock: String,
        allowed: Set<String>,
        taxonomy: Taxonomy,
        enrichments: [String: ContentEnricher.EnrichResult]?
    ) async throws -> [Decision] {
        guard !slice.isEmpty else { return [] }
        do {
            return try await classifyBatch(slice, folderBlock: folderBlock,
                                            allowed: allowed, taxonomy: taxonomy,
                                            enrichments: enrichments)
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as ClassifierError {
            switch err {
            case .contextOverflow where slice.count > config.minBatchSize:
                let mid = slice.count / 2
                async let left = classifySliceRobust(Array(slice[..<mid]), folderBlock: folderBlock,
                                                       allowed: allowed, taxonomy: taxonomy, enrichments: enrichments)
                async let right = classifySliceRobust(Array(slice[mid...]), folderBlock: folderBlock,
                                                        allowed: allowed, taxonomy: taxonomy, enrichments: enrichments)
                return try await left + right
            case .refused where slice.count > 1:
                var out: [Decision] = []
                for b in slice {
                    out += try await classifySliceRobust([b], folderBlock: folderBlock,
                                                           allowed: allowed, taxonomy: taxonomy, enrichments: enrichments)
                }
                return out
            default:
                unsortedCauses.unmapped += slice.count
                return slice.map { Decision(bookmarkID: $0.id, folder: Taxonomy.unsorted, confidence: 0) }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            unsortedCauses.unmapped += slice.count
            return slice.map { Decision(bookmarkID: $0.id, folder: Taxonomy.unsorted, confidence: 0) }
        }
    }

    /// Largest batch (up to `autoBatchCap`) whose rendered prompt still fits the
    /// live budget, so the same code adapts to whatever context window the OS
    /// reports rather than assuming one. A pinned `config.initialBatchSize` wins.
    func derivedInitialBatchSize(
        _ bookmarks: [Bookmark],
        folderBlock: String,
        enrichments: [String: ContentEnricher.EnrichResult]? = nil
    ) -> Int {
        guard config.initialBatchSize <= 0 else { return config.initialBatchSize }
        guard !bookmarks.isEmpty else { return 1 }

        var size = min(Self.autoBatchCap, bookmarks.count)
        while size > 1 {
            let probe = Self.renderPrompt(Array(bookmarks.prefix(size)),
                                          folderBlock: folderBlock,
                                          enrichments: enrichments)
            if budget.fits(instructions: Self.instructions, prompt: probe) { return size }
            size -= 1
        }
        return 1
    }

    // MARK: - One batch

    private func classifyBatch(
        _ slice: [Bookmark],
        folderBlock: String,
        allowed: Set<String>,
        taxonomy: Taxonomy,
        enrichments: [String: ContentEnricher.EnrichResult]? = nil
    ) async throws -> [Decision] {
        let prompt = Self.renderPrompt(slice, folderBlock: folderBlock, enrichments: enrichments)
        guard budget.fits(instructions: Self.instructions, prompt: prompt) else {
            throw ClassifierError.contextOverflow
        }

        let session = factory.makeSession(instructions: Self.instructions)

        var byLocalID: [String: Bookmark] = [:]
        for (i, b) in slice.enumerated() { byLocalID["b\(i)"] = b }

        var assignments: [(id: String, folder: String, confidence: Int)] = []

        if let schema {
            let content: GeneratedContent
            do {
                content = try await session.respond(to: prompt, schema: schema, options: factory.generationOptions).content
            } catch let e as LanguageModelSession.GenerationError {
                switch e {
                case .exceededContextWindowSize:
                    throw ClassifierError.contextOverflow
                case .refusal:
                    refusalCount += 1
                    throw ClassifierError.refused
                default:
                    throw ClassifierError.generation(String(describing: e))
                }
            }
            let rawAssignments = try content.value([GeneratedContent].self, forProperty: "assignments")
            for item in rawAssignments {
                let id = try item.value(String.self, forProperty: "id")
                let folder = try item.value(String.self, forProperty: "folder")
                let confidence = try item.value(Int.self, forProperty: "confidence")
                assignments.append((id: id, folder: folder, confidence: confidence))
            }
        } else {
            // Schema unavailable (should not happen when taxonomy is within cap).
            // Fall back to Unsorted for all items in this batch.
            for b in slice {
                assignments.append((id: b.id, folder: Taxonomy.unsorted, confidence: 0))
                unsortedCauses.unmapped += 1
            }
        }

        var out: [Decision] = []
        for a in assignments {
            guard let b = byLocalID[a.id.lowercased()] else { continue }
            let folder = Self.validate(a.folder, allowed: allowed, taxonomy: taxonomy)
            let conf = max(0, min(100, a.confidence))

            if folder == Taxonomy.unsorted {
                unsortedCauses.modelChoseUnsorted += 1
                out.append(Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: conf))
            } else if conf < config.confidenceFloor {
                unsortedCauses.belowFloor += 1
                out.append(Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: conf, modelChosenFolder: folder))
            } else {
                out.append(Decision(bookmarkID: b.id, folder: folder, confidence: conf))
            }
        }
        let returned = Set(out.map(\.bookmarkID))
        for b in slice where !returned.contains(b.id) {
            unsortedCauses.unmapped += 1
            out.append(Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: 0))
        }
        return out
    }

    // MARK: - Rendering & validation

    static func renderFolders(_ t: Taxonomy) -> String {
        let lines = t.folders.map { "- \($0.name)" + ($0.rationale.isEmpty ? "" : ": \($0.rationale)") }
        return (lines + ["- \(Taxonomy.unsorted): anything that fits nowhere above"]).joined(separator: "\n")
    }

    static func renderPrompt(
        _ slice: [Bookmark],
        folderBlock: String,
        enrichments: [String: ContentEnricher.EnrichResult]? = nil
    ) -> String {
        let items = slice.enumerated().map { i, b in
            var line = "b\(i) | \(b.title.isEmpty ? "(untitled)" : b.title) | \(b.url)"
            if let desc = enrichments?[b.id]?.metaDescription, !desc.isEmpty {
                line += " | \(desc)"
            }
            return line
        }.joined(separator: "\n")
        return """
        Allowed folders:
        \(folderBlock)

        Items:
        \(items)
        """
    }

    static func canonical(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exact match → case/space-insensitive match → Unsorted.
    static func validate(_ raw: String, allowed: Set<String>, taxonomy: Taxonomy) -> String {
        let c = canonical(raw)
        guard allowed.contains(c) else { return Taxonomy.unsorted }
        // Return the canonically-cased taxonomy name, not the model's casing.
        if c == canonical(Taxonomy.unsorted) { return Taxonomy.unsorted }
        return taxonomy.names.first { canonical($0) == c } ?? Taxonomy.unsorted
    }
}

public enum ClassifierError: Error, Sendable {
    case contextOverflow
    case refused
    case generation(String)
}
