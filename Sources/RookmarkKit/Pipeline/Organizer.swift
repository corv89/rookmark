import Foundation

public struct TaxonomyEnvelope: Codable, Sendable {
    public var v: Int
    public var folders: [Taxonomy.Folder]
    public init(v: Int, folders: [Taxonomy.Folder]) {
        self.v = v
        self.folders = folders
    }
}

/// Minimal classification seam so tests can drive `organize` without the
/// on-device model; the production implementation is `Classifier` itself.
protocol Classification: Sendable {
    func classify(
        _ bookmarks: [Bookmark],
        taxonomy: Taxonomy,
        enrichments: [String: ContentEnricher.EnrichResult]?,
        progress: Classifier.ProgressHandler?,
        onBatch: Classifier.BatchHandler?
    ) async throws -> [Classifier.Decision]
}

extension Classifier: Classification {}

/// Top-level orchestrator wiring the phases together. The CLI's `organize`
/// command is a thin shell over this.
public struct Organizer: Sendable {

    public struct Options: Sendable {
        public var taxonomyMode: TaxonomyBuilder.Mode
        public var classifier: Classifier.Config
        public var stateful: Bool
        public var storePath: String?
        public var sourcePath: String?
        public var clustering: ClusteringConfig
        public var constrainedFolderCap: Int
        public var embedderPreference: EmbedderFactory.Preference
        public var pinnedTaxonomy: Taxonomy?
        public var enrich: Bool
        public var refreshEnrichments: Bool
        public var enrichmentConfig: ContentEnricher.Config
        public init(
            taxonomyMode: TaxonomyBuilder.Mode = .preserve,
            classifier: Classifier.Config = .init(),
            stateful: Bool = false,
            storePath: String? = nil,
            sourcePath: String? = nil,
            clustering: ClusteringConfig = .init(),
            constrainedFolderCap: Int = 40,
            embedderPreference: EmbedderFactory.Preference = .contextual,
            pinnedTaxonomy: Taxonomy? = nil,
            enrich: Bool = true,
            refreshEnrichments: Bool = false,
            enrichmentConfig: ContentEnricher.Config = .init()
        ) {
            self.taxonomyMode = taxonomyMode
            self.classifier = classifier
            self.stateful = stateful
            self.storePath = storePath
            self.sourcePath = sourcePath
            self.clustering = clustering
            self.constrainedFolderCap = constrainedFolderCap
            self.embedderPreference = embedderPreference
            self.pinnedTaxonomy = pinnedTaxonomy
            self.enrich = enrich
            self.refreshEnrichments = refreshEnrichments
            self.enrichmentConfig = enrichmentConfig
        }
    }

    public struct Result: Sendable {
        public var bookmarks: [Bookmark]   // with assignedFolder/confidence filled
        public var taxonomy: Taxonomy
        public var unsortedCauses: Classifier.UnsortedCauses
        public var deadLinks: [(title: String, url: String, reason: String)]
        public var enrichmentCount: Int
        /// Per-item decisions, including `modelChosenFolder` — the folder the model
        /// picked before the confidence floor or validation could override it. A UI
        /// needs this to explain *why* something landed in Unsorted.
        public var decisions: [Classifier.Decision]
    }

    private let factory: SessionFactory
    private let makeClassifier: @Sendable (Classifier.Config, TokenBudget, Taxonomy) -> any Classification

    public init(factory: SessionFactory = SessionFactory()) {
        self.factory = factory
        self.makeClassifier = { config, budget, taxonomy in
            Classifier(factory: factory, config: config, budget: budget, taxonomy: taxonomy)
        }
    }

    /// Test seam: inject a deterministic classifier (see OrganizerResumeTests).
    init(
        factory: SessionFactory,
        makeClassifier: @escaping @Sendable (Classifier.Config, TokenBudget, Taxonomy) -> any Classification
    ) {
        self.factory = factory
        self.makeClassifier = makeClassifier
    }

    /// One-shot, in-memory by default. With `options.stateful`, route through
    /// `Store` for per-batch commit + resume (see ImplementationPlan.md).
    public enum Error: Swift.Error, Sendable {
        case modelUnavailable(String)
        case contextualEmbedderUnavailable
    }

    public typealias EnrichmentProgressHandler = @Sendable (_ done: Int, _ total: Int) -> Void
    public typealias DeadLinkHandler = @Sendable (_ title: String, _ url: String, _ reason: String) -> Void
    /// Fired once, before classification starts, when a stateful run is resumed.
    public typealias ResumeHandler = @Sendable (_ alreadyClassified: Int, _ total: Int) -> Void

    public func organize(
        html: String,
        options: Options,
        enrichmentProgress: EnrichmentProgressHandler? = nil,
        onDeadLink: DeadLinkHandler? = nil,
        progress: Classifier.ProgressHandler? = nil,
        onBatch: Classifier.BatchHandler? = nil,
        onResume: ResumeHandler? = nil
    ) async throws -> Result {
        guard case .available = factory.availability() else {
            if case let .unavailable(reason) = factory.availability() {
                throw Error.modelUnavailable(reason)
            }
            throw Error.modelUnavailable("Unknown")
        }

        var parse = NetscapeBookmarkParser().parse(html)
        parse.bookmarks.sort { $0.id < $1.id }
        let ctx = factory.contextSize()
        let budget = TokenBudget(total: ctx)

        var taxonomy: Taxonomy
        if let pinned = options.pinnedTaxonomy {
            taxonomy = pinned
        } else {
            taxonomy = try await TaxonomyBuilder(factory: factory, budget: budget)
                .build(from: parse, mode: options.taxonomyMode, folderLanguage: options.clustering.folderLanguage)
        }

        if taxonomy.folders.count > options.constrainedFolderCap {
            taxonomy = TaxonomyBuilder.pruneToCap(taxonomy, cap: options.constrainedFolderCap)
        }

        let store: Store?
        var runID: Int64?
        var committedDecisions: [Classifier.Decision] = []
        var toClassify = parse.bookmarks   // resume filtering happens AFTER the id-sort above
        if options.stateful, let path = options.storePath ?? options.sourcePath.map({ $0 + ".db" }) {
            let s = try Store(path: path)
            let source = options.sourcePath ?? ""
            let rid: Int64
            if let prior = try s.latestUnfinishedRun(sourcePath: source) {
                rid = prior   // reuse, never a duplicate run
                let allRows = try s.all(runID: rid)
                let pendingIDs = Set(try s.uncommitted(runID: rid).map(\.id))
                // upsert resets committed=0, so only insert ids this run has never
                // seen; re-upserting would discard the work resume exists to keep.
                let known = Set(allRows.map(\.id))
                try s.upsert(parse.bookmarks.filter { !known.contains($0.id) }, runID: rid)
                committedDecisions = Self.committedDecisions(parse.bookmarks, allRows: allRows, pendingIDs: pendingIDs)
                toClassify = parse.bookmarks.filter { pendingIDs.contains($0.id) }
                onResume?(committedDecisions.count, parse.bookmarks.count)
            } else {
                rid = try s.createRun(sourcePath: source)
                try s.upsert(parse.bookmarks, runID: rid)
            }
            try s.snapshot(runID: rid)
            store = s
            runID = rid
        } else {
            store = nil
        }

        var enrichments: [String: ContentEnricher.EnrichResult]?
        var deadLinkList: [(title: String, url: String, reason: String)] = []
        var enrichmentCount = 0
        if options.enrich {
            let enricher = ContentEnricher(config: options.enrichmentConfig, store: store)
            let results = await enricher.enrich(
                parse.bookmarks,
                refresh: options.refreshEnrichments,
                progress: enrichmentProgress,
                onDeadLink: onDeadLink
            )
            enrichments = results
            deadLinkList = await enricher.getDeadLinks()
            enrichmentCount = results.filter { $0.value.metaDescription != nil }.count
        }

        var classifierConfig = options.classifier
        if options.enrich && enrichments != nil {
            let enrichedCount = enrichments?.filter { $0.value.metaDescription != nil }.count ?? 0
            // Only needed when the size is pinned; the derived path already
            // measures a prompt that includes the descriptions.
            if enrichedCount > 0, classifierConfig.initialBatchSize > 0 {
                classifierConfig.initialBatchSize = min(classifierConfig.initialBatchSize, 4)
            }
        }

        // Per-batch commit (ImplementationPlan.md §9): compose the caller's onBatch
        // with a store write so each batch is durable the moment it lands. commit is
        // an idempotent last-write-wins UPDATE, so Phase 2 revisions simply overwrite.
        // A failed per-batch commit is non-fatal: the end-of-run commit retries and
        // an interrupted run just resumes those items.
        let batchHandler: Classifier.BatchHandler?
        if let store, let runID {
            let s = store, r = runID
            batchHandler = { batch in
                try? s.commit(batch, runID: r)
                onBatch?(batch)
            }
        } else {
            batchHandler = onBatch   // stateless: identical closure, zero new work
        }

        let classifier = makeClassifier(classifierConfig, budget, taxonomy)
        let newDecisions = try await classifier.classify(
            toClassify, taxonomy: taxonomy, enrichments: enrichments,
            progress: progress, onBatch: batchHandler)

        // Merge committed + fresh in parse order — the array an uninterrupted run
        // would have assembled (determinism guard: parse.bookmarks is id-sorted).
        var decisions: [Classifier.Decision]
        if committedDecisions.isEmpty {
            decisions = newDecisions
        } else {
            let newByID = Dictionary(uniqueKeysWithValues: newDecisions.map { ($0.bookmarkID, $0) })
            let committedByID = Dictionary(uniqueKeysWithValues: committedDecisions.map { ($0.bookmarkID, $0) })
            decisions = parse.bookmarks.compactMap { newByID[$0.id] ?? committedByID[$0.id] }
        }


        if options.clustering.enabled {
            let residueIDs = Set(decisions.filter { $0.folder == Taxonomy.unsorted }.map(\.bookmarkID))
            let residue = parse.bookmarks.filter { residueIDs.contains($0.id) }

            if residue.count >= options.clustering.minResidue {
                let embedder = await EmbedderFactory.makeAsync(preferred: options.embedderPreference)
                if options.embedderPreference == .contextual && embedder == nil {
                    throw Error.contextualEmbedderUnavailable
                }
                // Apply per-embedder-family default thresholds when not explicitly overridden.
                var clusteringCfg = options.clustering
                if clusteringCfg.similarityThreshold < 0 {
                    let t = EmbedderFactory.defaultThresholds(for: embedder?.modelID ?? "")
                    clusteringCfg.similarityThreshold = t.similarity
                }
                if clusteringCfg.mergeThreshold < 0 {
                    let t = EmbedderFactory.defaultThresholds(for: embedder?.modelID ?? "")
                    clusteringCfg.mergeThreshold = t.merge
                }
                let clusterer = Clusterer(factory: factory, budget: budget, config: clusteringCfg, embedder: embedder)

                let embeddingCache: [String: [Float]]
                if let store, let embedder {
                    let residueIDSet = Set(residue.map(\.id))
                    embeddingCache = (try? store.loadEmbeddings(bookmarkIDs: residueIDSet, model: embedder.modelID)) ?? [:]
                } else {
                    embeddingCache = [:]
                }

                let vectors = clusterer.embed(residue, cache: embeddingCache)

                if let store, let runID, let embedder {
                    let newVectors = vectors.filter { !embeddingCache.keys.contains($0.key) }
                    if !newVectors.isEmpty {
                        try? store.cacheEmbeddings(newVectors, runID: runID, model: embedder.modelID)
                    }
                }
                let clusters = clusterer.cluster(vectors)

                if !clusters.isEmpty {
                    let proposed = try await clusterer.name(clusters, bookmarks: residue, existing: taxonomy.names)
                    let merged = await clusterer.merge(proposed, existing: taxonomy.folders)

                    if !merged.isEmpty {
                        taxonomy = Taxonomy(folders: taxonomy.folders + merged)

                        if taxonomy.folders.count > options.constrainedFolderCap {
                            taxonomy = TaxonomyBuilder.pruneToCap(taxonomy, cap: options.constrainedFolderCap)
                        }

                        let reClassifier = makeClassifier(options.classifier, budget, taxonomy)
                        // Re-placements revise rows the UI already showed, so they
                        // go out through onBatch too.
                        let residueDecisions = try await reClassifier.classify(
                            residue, taxonomy: taxonomy, enrichments: nil, progress: nil, onBatch: batchHandler
                        )

                        let residueDecisionMap = Dictionary(uniqueKeysWithValues: residueDecisions.map { ($0.bookmarkID, $0) })
                        for i in decisions.indices {
                            if let updated = residueDecisionMap[decisions[i].bookmarkID] {
                                decisions[i] = updated
                            }
                        }
                    }
                }
            }
        }

        var bookmarks = parse.bookmarks
        let decisionMap = Dictionary(uniqueKeysWithValues: decisions.map { ($0.bookmarkID, $0) })
        for i in bookmarks.indices {
            if let d = decisionMap[bookmarks[i].id] {
                bookmarks[i].assignedFolder = d.folder
                bookmarks[i].confidence = d.confidence
            }
        }

        // Recompute final Unsorted breakdown from the post-reclassification decisions.
        // We walk the final decisions array (which may have Phase 2 replacements)
        // rather than summing classifier accumulators, which double-counts when
        // Phase 2 rescues bookmarks that Phase 1 put in Unsorted.
        var finalCauses = Classifier.UnsortedCauses()
        let allBookmarkIDs = Set(parse.bookmarks.map(\.id))
        let decidedIDs = Set(decisions.map(\.bookmarkID))
        let floor = options.classifier.confidenceFloor
        for d in decisions {
            if d.folder == Taxonomy.unsorted {
                if d.confidence >= floor {
                    finalCauses.modelChoseUnsorted += 1
                } else {
                    finalCauses.belowFloor += 1
                }
            }
        }
        finalCauses.unmapped = allBookmarkIDs.subtracting(decidedIDs).count

        if let store, let runID {
            try store.commit(decisions, runID: runID)
            let taxonomyData = try JSONEncoder().encode(TaxonomyEnvelope(v: 2, folders: taxonomy.folders))
            let causes = finalCauses
            let summary: [String: Any] = [
                "unsorted_model_chose": causes.modelChoseUnsorted,
                "unsorted_below_floor": causes.belowFloor,
                "unsorted_unmapped": causes.unmapped,
                "folders_count": taxonomy.folders.count,
            ]
            let summaryData = try JSONSerialization.data(withJSONObject: summary)
            let summaryJSON = String(data: summaryData, encoding: .utf8)
            try store.finishRun(
                runID,
                taxonomyJSON: String(data: taxonomyData, encoding: .utf8) ?? "[]",
                summaryJSON: summaryJSON
            )
        }

        return Result(
            bookmarks: bookmarks,
            taxonomy: taxonomy,
            unsortedCauses: finalCauses,
            deadLinks: deadLinkList,
            enrichmentCount: enrichmentCount,
            decisions: decisions
        )
    }

    /// Rebuilds the run's committed decisions, in `bookmarks` order, from stored
    /// rows. `modelChosenFolder` is not persisted; it is GUI-only explain-data
    /// and is regenerated by Phase 2 for anything re-classified.
    private static func committedDecisions(
        _ bookmarks: [Bookmark], allRows: [Bookmark], pendingIDs: Set<String>
    ) -> [Classifier.Decision] {
        let byID = Dictionary(uniqueKeysWithValues:
            allRows.filter { !pendingIDs.contains($0.id) }.map { ($0.id, $0) })
        return bookmarks.compactMap { b in
            guard let row = byID[b.id] else { return nil }
            return Classifier.Decision(
                bookmarkID: b.id,
                folder: row.assignedFolder ?? Taxonomy.unsorted,
                confidence: row.confidence ?? 0)
        }
    }
}
