import Foundation

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
        public init(
            taxonomyMode: TaxonomyBuilder.Mode = .preserve,
            classifier: Classifier.Config = .init(),
            stateful: Bool = false,
            storePath: String? = nil,
            sourcePath: String? = nil,
            clustering: ClusteringConfig = .init(),
            constrainedFolderCap: Int = 40,
            embedderPreference: EmbedderFactory.Preference = .auto
        ) {
            self.taxonomyMode = taxonomyMode
            self.classifier = classifier
            self.stateful = stateful
            self.storePath = storePath
            self.sourcePath = sourcePath
            self.clustering = clustering
            self.constrainedFolderCap = constrainedFolderCap
            self.embedderPreference = embedderPreference
        }
    }

    public struct Result: Sendable {
        public var bookmarks: [Bookmark]   // with assignedFolder/confidence filled
        public var taxonomy: Taxonomy
        public var unsortedCauses: Classifier.UnsortedCauses
    }

    private let factory: SessionFactory

    public init(factory: SessionFactory = SessionFactory()) {
        self.factory = factory
    }

    /// One-shot, in-memory by default. With `options.stateful`, route through
    /// `Store` for per-batch commit + resume (see ImplementationPlan.md).
    public enum Error: Swift.Error, Sendable {
        case modelUnavailable(String)
    }

    public func organize(
        html: String,
        options: Options,
        progress: Classifier.ProgressHandler? = nil
    ) async throws -> Result {
        guard case .available = factory.availability() else {
            if case let .unavailable(reason) = factory.availability() {
                throw Error.modelUnavailable(reason)
            }
            throw Error.modelUnavailable("Unknown")
        }

        let parse = NetscapeBookmarkParser().parse(html)
        let ctx = factory.contextSize()
        let budget = TokenBudget(total: ctx)

        var taxonomy = try await TaxonomyBuilder(factory: factory, budget: budget)
            .build(from: parse, mode: options.taxonomyMode, folderLanguage: options.clustering.folderLanguage)

        if taxonomy.folders.count > options.constrainedFolderCap {
            taxonomy = TaxonomyBuilder.pruneToCap(taxonomy, cap: options.constrainedFolderCap)
        }

        let store: Store?
        var runID: Int64?
        if options.stateful, let path = options.storePath ?? options.sourcePath.map({ $0 + ".db" }) {
            let s = try Store(path: path)
            let rid = try s.createRun(sourcePath: options.sourcePath ?? "")
            try s.upsert(parse.bookmarks, runID: rid)
            try s.snapshot(runID: rid)
            store = s
            runID = rid
        } else {
            store = nil
        }

        let classifier = Classifier(factory: factory, config: options.classifier, budget: budget, taxonomy: taxonomy)
        var decisions = await classifier.classify(parse.bookmarks, taxonomy: taxonomy, progress: progress)
        var reClassifierCauses: Classifier.UnsortedCauses?

        if options.clustering.enabled {
            let residueIDs = Set(decisions.filter { $0.folder == Taxonomy.unsorted }.map(\.bookmarkID))
            let residue = parse.bookmarks.filter { residueIDs.contains($0.id) }

            if residue.count >= options.clustering.minResidue {
                let embedder = await EmbedderFactory.makeBestAsync(preferred: options.embedderPreference)
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
                let vectors = clusterer.embed(residue)
                let clusters = clusterer.cluster(vectors)

                if !clusters.isEmpty {
                    let proposed = try await clusterer.name(clusters, bookmarks: residue, existing: taxonomy.names)
                    let merged = await clusterer.merge(proposed, existing: taxonomy.folders)

                    if !merged.isEmpty {
                        taxonomy = Taxonomy(folders: taxonomy.folders + merged)

                        if taxonomy.folders.count > options.constrainedFolderCap {
                            taxonomy = TaxonomyBuilder.pruneToCap(taxonomy, cap: options.constrainedFolderCap)
                        }

                        let reClassifier = Classifier(factory: factory, config: options.classifier, budget: budget, taxonomy: taxonomy)
                        let residueDecisions = await reClassifier.classify(residue, taxonomy: taxonomy)
                        reClassifierCauses = await reClassifier.unsortedCauses

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

        // Compute final Unsorted breakdown from the post-reclassification decisions.
        let classifierCauses = await classifier.unsortedCauses
        var finalCauses = classifierCauses
        if let reClassifierCauses = reClassifierCauses {
            finalCauses = Classifier.UnsortedCauses(
                modelChoseUnsorted: classifierCauses.modelChoseUnsorted + reClassifierCauses.modelChoseUnsorted,
                belowFloor: classifierCauses.belowFloor + reClassifierCauses.belowFloor,
                unmapped: classifierCauses.unmapped + reClassifierCauses.unmapped
            )
        }

        if let store, let runID {
            try store.commit(decisions, runID: runID)
            let taxonomyData = try JSONEncoder().encode(taxonomy.names)
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

        return Result(bookmarks: bookmarks, taxonomy: taxonomy, unsortedCauses: finalCauses)
    }
}
