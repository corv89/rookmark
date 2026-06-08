import ArgumentParser
import Foundation
import LazyBookmarksKit
import EvalKit

struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Evaluation & tuning harness.",
        subcommands: [
            EvalRun.self,
            EvalSample.self,
            EvalImportLabels.self,
            EvalMetrics.self,
            EvalCalib.self,
            EvalSweep.self,
            EvalSubsample.self,
            EvalBaseline.self,
            EvalCheck.self,
            EvalJudge.self,
        ]
    )
}

// MARK: - Shared helpers

enum EvalCLI {
    static func defaultLabelsDB(for input: String) -> String {
        (input as NSString).deletingPathExtension + ".labels.db"
    }

    static func loadPinnedTaxonomy(input: String, reuseRunID: Int64?, taxonomyPath: String?) throws -> Taxonomy? {
        if let runID = reuseRunID {
            let dbPath = input + ".db"
            let store = try Store(path: dbPath)
            guard let t = try store.loadTaxonomy(runID: runID) else {
                throw ValidationError("No taxonomy found for run #\(runID).")
            }
            if t.folders.contains(where: { $0.rationale.isEmpty }) {
                FileHandle.standardError.write(Data("warning: pinned taxonomy predates rationale storage\n".utf8))
            }
            return t
        } else if let path = taxonomyPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let envelope = try JSONDecoder().decode(TaxonomyEnvelope.self, from: data)
            return Taxonomy(folders: envelope.folders)
        }
        return nil
    }

    static func checkModel(_ factory: SessionFactory) throws {
        guard case .available = factory.availability() else {
            if case let .unavailable(reason) = factory.availability() {
                throw ValidationError(reason)
            }
            throw ValidationError("Model unavailable.")
        }
    }
}

// MARK: - eval run (variance harness)

struct EvalRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the pipeline N times and report variance statistics."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(help: "Number of runs (default: 5).")
    var runs: Int = 5

    @Option(name: .customLong("embedder"), help: "Embedding backend: 'sentence' or 'contextual'.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Minimum confidence (0-100).")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Initial classification batch size.")
    var batchSize: Int = 6

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)
        guard runs >= 2 else {
            throw ValidationError("--runs must be >= 2 to compute variance.")
        }

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let clusteringConfig = ClusteringConfig(enabled: cluster)

        struct RunStats {
            var sortRate: Double
            var folderCount: Int
            var unsortedTotal: Int
            var modelChose: Int
            var belowFloor: Int
            var unmapped: Int
        }

        var allStats: [RunStats] = []
        let organizer = Organizer()

        for i in 1...runs {
            FileHandle.standardError.write(Data("Run \(i)/\(runs)...\n".utf8))
            let opts = Organizer.Options(
                taxonomyMode: .fresh,
                classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
                clustering: clusteringConfig,
                embedderPreference: embedderPref
            )
            let result = try await organizer.organize(html: html, options: opts)
            let total = result.bookmarks.count
            let placed = result.bookmarks.filter { ($0.assignedFolder ?? Taxonomy.unsorted) != Taxonomy.unsorted }.count
            let causes = result.unsortedCauses
            allStats.append(RunStats(
                sortRate: total > 0 ? Double(placed) / Double(total) * 100 : 0,
                folderCount: result.taxonomy.folders.count,
                unsortedTotal: total - placed,
                modelChose: causes.modelChoseUnsorted,
                belowFloor: causes.belowFloor,
                unmapped: causes.unmapped
            ))
        }

        func stats(_ values: [Double]) -> (mean: Double, stddev: Double, min: Double, max: Double) {
            guard !values.isEmpty else { return (0, 0, 0, 0) }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            let stddev = sqrt(variance)
            return (mean, stddev, values.min()!, values.max()!)
        }

        let sortRates = allStats.map(\.sortRate)
        let folderCounts = allStats.map { Double($0.folderCount) }
        let unsortedTotals = allStats.map { Double($0.unsortedTotal) }
        let modelChoses = allStats.map { Double($0.modelChose) }
        let belowFloors = allStats.map { Double($0.belowFloor) }
        let unmappeds = allStats.map { Double($0.unmapped) }

        let s1 = stats(sortRates)
        let s2 = stats(folderCounts)
        let s3 = stats(unsortedTotals)
        let s4 = stats(modelChoses)
        let s5 = stats(belowFloors)
        let s6 = stats(unmappeds)

        let bookmarkCount = allStats.first.map { m -> Int in
            guard m.sortRate < 100 else { return m.unsortedTotal }
            return Int(round(Double(m.unsortedTotal) / (1.0 - m.sortRate / 100.0)))
        } ?? 0

        print("lazybm eval: \(runs) runs on \(input) (\(bookmarkCount) bookmarks)")
        print("")
        print(String(format: "%-20s%-10s%-10s%-10s%-10s%-10s", "Metric", "Mean", "StdDev", "Min", "Max", "Range"))
        print(String(repeating: "\u{2500}", count: 65))

        func row(_ label: String, _ s: (mean: Double, stddev: Double, min: Double, max: Double)) {
            let range = s.max - s.min
            print(String(format: "%-20s%-10.1f%-10.1f%-10.1f%-10.1f%-10.1f",
                         label, s.mean, s.stddev, s.min, s.max, range))
        }

        func intRow(_ label: String, _ s: (mean: Double, stddev: Double, min: Double, max: Double)) {
            let range = s.max - s.min
            print(String(format: "%-20s%-10.0f%-10.1f%-10.0f%-10.0f%-10.0f",
                         label, s.mean, s.stddev, s.min, s.max, range))
        }

        row("Sort rate (%)", s1)
        intRow("Folder count", s2)
        intRow("Unsorted total", s3)
        intRow("  model-chose", s4)
        intRow("  below-floor", s5)
        intRow("  unmapped", s6)
    }
}

// MARK: - eval sample

struct EvalSample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample",
        abstract: "Emit a stratified labeling worksheet (CSV) for human annotation."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(help: "Sample size.")
    var n: Int = 200

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend: 'sentence' or 'contextual'.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Minimum confidence (0-100).")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Initial classification batch size.")
    var batchSize: Int = 6

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let organizer = Organizer()
        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        FileHandle.standardError.write(Data("Running pipeline...\n".utf8))
        let result = try await organizer.organize(html: html, options: opts)

        let decisions: [Classifier.Decision] = result.bookmarks.map { b in
            Classifier.Decision(
                bookmarkID: b.id,
                folder: b.assignedFolder ?? Taxonomy.unsorted,
                confidence: b.confidence ?? 0
            )
        }

        let rows = Sampler.stratifiedSample(
            decisions: decisions,
            bookmarks: result.bookmarks,
            n: n,
            seed: 42
        )

        FileHandle.standardError.write(Data("Sampled \(rows.count) bookmarks for labeling.\n".utf8))
        print(Sampler.toCSV(rows))
    }
}

// MARK: - eval import-labels

struct EvalImportLabels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-labels",
        abstract: "Import human accept/reject labels from a CSV file."
    )

    @Argument(help: "Path to the CSV file with labels.")
    var file: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database. Defaults to <input>.labels.db")
    var labelsDB: String?

    @Option(help: "Path to the original HTML file (used to derive labels DB path).")
    var input: String?

    func run() throws {
        let dbPath: String
        if let labelsDB {
            dbPath = labelsDB
        } else if let input {
            dbPath = EvalCLI.defaultLabelsDB(for: input)
        } else {
            throw ValidationError("Specify --labels-db or --input.")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let store = try LabelStore(path: dbPath)
        let count = try store.importCSV(data)
        print("Imported \(count) labels into \(dbPath)")
    }
}

// MARK: - eval metrics

struct EvalMetrics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Compute classification metrics with bootstrap CIs against human labels."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database.")
    var labelsDB: String?

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend: 'sentence' or 'contextual'.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Minimum confidence (0-100).")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Initial classification batch size.")
    var batchSize: Int = 6

    @Option(help: "Bootstrap iterations for CI.")
    var bootstrap: Int = 1000

    @Option(help: "Random seed for reproducibility.")
    var seed: UInt64 = 42

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let dbPath = labelsDB ?? EvalCLI.defaultLabelsDB(for: input)
        let labelStore = try LabelStore(path: dbPath)
        let labels = try labelStore.labelsByKey()
        guard !labels.isEmpty else {
            throw ValidationError("No labels found in \(dbPath). Run `eval sample` and `eval import-labels` first.")
        }

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let organizer = Organizer()
        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        FileHandle.standardError.write(Data("Running pipeline...\n".utf8))
        let result = try await organizer.organize(html: html, options: opts)

        let decisions: [Classifier.Decision] = result.bookmarks.map { b in
            Classifier.Decision(
                bookmarkID: b.id,
                folder: b.assignedFolder ?? Taxonomy.unsorted,
                confidence: b.confidence ?? 0
            )
        }

        let m = Metrics.compute(decisions: decisions, labels: labels)

        let yields = [Double](repeating: m.yield, count: m.total)
        let precisions = decisions.compactMap { d -> Double? in
            guard d.folder != Taxonomy.unsorted else { return nil }
            let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
            guard let label = labels[key] else { return nil }
            return label.verdict == .accept ? 1.0 : 0.0
        }

        let yieldCI = Metrics.bootstrapCI(yields, iterations: bootstrap, seed: seed)
        let precisionCI = Metrics.bootstrapCI(precisions, iterations: bootstrap, seed: seed &+ 1)

        print("Classification metrics on \(input) (\(m.total) bookmarks, \(labels.count) labels)")
        print("")
        print(String(format: "Coverage:   %.1f%%", m.coverage * 100))
        print(String(format: "Precision:  %.1f%%  [%.1f%%, %.1f%%]",
                     m.precision * 100, precisionCI.lower * 100, precisionCI.upper * 100))
        print(String(format: "Yield:      %.1f%%  [%.1f%%, %.1f%%]",
                     m.yield * 100, yieldCI.lower * 100, yieldCI.upper * 100))
        print(String(format: "Recall:     %.1f%%", m.recall * 100))
        print("")
        print("Placed: \(m.placed)  Accepted: \(m.accepted)  Wrongly-Unsorted: \(m.wronglyUnsorted)")
    }
}

// MARK: - eval calib

struct EvalCalib: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calib",
        abstract: "Confidence-bin calibration curve and post-hoc floor sweep."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database.")
    var labelsDB: String?

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend: 'sentence' or 'contextual'.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Run confidence floor (use 0 for full calibration data).")
    var confidenceFloor: Int = 0

    @Option(name: .customLong("batch-size"), help: "Initial classification batch size.")
    var batchSize: Int = 6

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let dbPath = labelsDB ?? EvalCLI.defaultLabelsDB(for: input)
        let labelStore = try LabelStore(path: dbPath)
        let labels = try labelStore.labelsByKey()
        guard !labels.isEmpty else {
            throw ValidationError("No labels found in \(dbPath).")
        }

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let organizer = Organizer()
        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        FileHandle.standardError.write(Data("Running pipeline (floor=\(confidenceFloor))...\n".utf8))
        let result = try await organizer.organize(html: html, options: opts)

        let decisions: [Classifier.Decision] = result.bookmarks.map { b in
            Classifier.Decision(
                bookmarkID: b.id,
                folder: b.assignedFolder ?? Taxonomy.unsorted,
                confidence: b.confidence ?? 0
            )
        }

        let bins = FloorAnalysis.calibrate(decisions: decisions, labels: labels)
        let sweep = FloorAnalysis.floorSweep(decisions: decisions, labels: labels)

        let labeledCount = labels.count
        print("Calibration on \(input) (\(result.bookmarks.count) bookmarks, \(labeledCount) labels)")
        print("")
        print("Confidence bins:")
        print(String(format: "%-10s%-10s%-10s%-10s", "Bin", "Placed", "Accepted", "Precision"))
        print(String(repeating: "\u{2500}", count: 40))
        for b in bins {
            print(String(format: "%-10s%-10d%-10d%-10.1f",
                         "\(b.floor)-\(b.ceiling)", b.placed, b.accepted, b.precision * 100))
        }

        print("")
        print("Floor sweep (simulated):")
        print(String(format: "%-10s%-10s%-12s%-12s", "Floor", "Yield", "Precision", "Coverage"))
        print(String(repeating: "\u{2500}", count: 44))
        for p in sweep {
            print(String(format: "%-10d%-10.1f%-12.1f%-12.1f",
                         p.floor, p.yield * 100, p.precision * 100, p.coverage * 100))
        }
    }
}

// MARK: - eval sweep

struct EvalSweep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sweep",
        abstract: "Sweep a parameter and report per-value metrics with paired bootstrap."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: .customLong("param"), help: "Parameter to sweep (confidenceFloor, batchSize, similarityThreshold, mergeThreshold, maxNewFolders, minClusterSize, minResidue).")
    var param: String

    @Option(name: .customLong("values"), help: "Comma-separated values to try.")
    var values: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database.")
    var labelsDB: String?

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Base confidence floor.")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Base batch size.")
    var batchSize: Int = 6

    @Option(help: "Bootstrap iterations.")
    var bootstrap: Int = 1000

    @Option(help: "Random seed.")
    var seed: UInt64 = 42

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let dbPath = labelsDB ?? EvalCLI.defaultLabelsDB(for: input)
        let labelStore = try LabelStore(path: dbPath)
        let labels = try labelStore.labelsByKey()
        guard !labels.isEmpty else {
            throw ValidationError("No labels found in \(dbPath).")
        }

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let baseOpts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        let organizer = Organizer()
        let vals = values.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        FileHandle.standardError.write(Data("Sweeping \(param) over \(vals.count) values...\n".utf8))
        let results = try await Sweep.run(
            html: html,
            baseOptions: baseOpts,
            param: param,
            values: vals,
            labels: labels,
            organizer: organizer,
            bootstrapIterations: bootstrap,
            seed: seed
        )

        print("Sweep: \(param) on \(input) (\(labels.count) labels)")
        print("")
        print(String(format: "%-10s%-10s%-12s%-12s%-10s%-20s",
                     "Value", "Yield", "Precision", "Coverage", "CI", "Paired vs baseline"))
        print(String(repeating: "\u{2500}", count: 74))
        for r in results {
            let ciStr = String(format: "[%.0f,%.0f]", r.ci.lower * 100, r.ci.upper * 100)
            let pairedStr: String
            if let p = r.pairedVsBaseline {
                pairedStr = String(format: "%+.1f%% %@", p.meanDiff * 100, p.significant ? "*" : "")
            } else {
                pairedStr = "(baseline)"
            }
            print(String(format: "%-10s%-10.1f%-12.1f%-12.1f%-10s%-20s",
                         r.paramValue, r.metrics.yield * 100, r.metrics.precision * 100,
                         r.metrics.coverage * 100, ciStr, pairedStr))
        }
    }
}

// MARK: - eval subsample

struct EvalSubsample: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subsample",
        abstract: "Run pipeline on random subsets to measure stability."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(help: "Fraction of bookmarks per trial (0.0-1.0).")
    var fraction: Double = 0.7

    @Option(help: "Number of trials.")
    var trials: Int = 10

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Confidence floor.")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Batch size.")
    var batchSize: Int = 6

    @Option(help: "Random seed.")
    var seed: UInt64 = 42

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        let organizer = Organizer()
        FileHandle.standardError.write(Data("Running \(trials) trials at \(Int(fraction * 100))% subsample...\n".utf8))

        let stability = try await Subsample.stability(
            html: html,
            options: opts,
            fraction: fraction,
            trials: trials,
            organizer: organizer,
            seed: seed
        )

        print("Subsample stability: \(trials) trials at \(Int(fraction * 100))%")
        print("")
        print(String(format: "Mean yield:     %.1f%% (sd %.1f)",
                     stability.metricMeans.yield * 100,
                     Double(stability.metricStddevs.accepted) / Double(max(1, stability.metricMeans.total)) * 100))
        print(String(format: "Mean coverage:  %.1f%% (sd %.1f)",
                     stability.metricMeans.coverage * 100,
                     Double(stability.metricStddevs.placed) / Double(max(1, stability.metricMeans.total)) * 100))
        print(String(format: "Taxonomy Jaccard: %.3f", stability.taxonomyJaccard))
    }
}

// MARK: - eval baseline

struct EvalBaseline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline",
        abstract: "Capture a frozen regression baseline (prints JSON to stdout)."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database.")
    var labelsDB: String?

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Confidence floor.")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Batch size.")
    var batchSize: Int = 6

    @Option(help: "Bootstrap iterations.")
    var bootstrap: Int = 1000

    @Option(help: "Random seed.")
    var seed: UInt64 = 42

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let dbPath = labelsDB ?? EvalCLI.defaultLabelsDB(for: input)
        let labelStore = try LabelStore(path: dbPath)
        let labels = try labelStore.labelsByKey()
        guard !labels.isEmpty else {
            throw ValidationError("No labels found in \(dbPath).")
        }

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        let organizer = Organizer()
        FileHandle.standardError.write(Data("Capturing baseline...\n".utf8))

        let result = try await RegressionCheck.captureBaseline(
            html: html,
            options: opts,
            labels: labels,
            organizer: organizer,
            bootstrapIterations: bootstrap,
            seed: seed
        )

        FileHandle.standardError.write(Data((result.report + "\n\n").utf8))

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(result.baseline)
        print(String(data: data, encoding: .utf8)!)
    }
}

// MARK: - eval check

struct EvalCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run regression check against a frozen baseline."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database.")
    var labelsDB: String?

    @Option(name: .customLong("baseline"), help: "Path to the baseline JSON file.")
    var baselinePath: String

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Confidence floor.")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Batch size.")
    var batchSize: Int = 6

    @Option(help: "Bootstrap iterations.")
    var bootstrap: Int = 1000

    @Option(help: "Random seed.")
    var seed: UInt64 = 42

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let dbPath = labelsDB ?? EvalCLI.defaultLabelsDB(for: input)
        let labelStore = try LabelStore(path: dbPath)
        let labels = try labelStore.labelsByKey()
        guard !labels.isEmpty else {
            throw ValidationError("No labels found in \(dbPath).")
        }

        let baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
        let baseline = try JSONDecoder().decode(Baseline.self, from: baselineData)

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        let organizer = Organizer()
        FileHandle.standardError.write(Data("Running regression check...\n".utf8))

        let report = try await RegressionCheck.check(
            html: html,
            options: opts,
            labels: labels,
            baseline: baseline,
            organizer: organizer,
            bootstrapIterations: bootstrap,
            seed: seed
        )

        print(report.report)
        if !report.pass {
            throw ExitCode.failure
        }
    }
}

// MARK: - eval judge

struct EvalJudge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "judge",
        abstract: "Calibrate an LLM judge against human labels and bulk-label."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(name: .customLong("labels-db"), help: "Path to the labels database.")
    var labelsDB: String?

    @Option(name: .customLong("pin-taxonomy"), help: "Pin taxonomy from a previous run ID.")
    var pinTaxonomy: Int64?

    @Option(name: .customLong("taxonomy-from"), help: "Load taxonomy from a JSON file.")
    var taxonomyFrom: String?

    @Option(name: .customLong("embedder"), help: "Embedding backend.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Confidence floor.")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Batch size.")
    var batchSize: Int = 6

    @Option(name: .customLong("base-url"), help: "LM Studio base URL.")
    var baseURL: String = "http://localhost:1234/v1"

    @Option(help: "LM Studio model name.")
    var model: String = "qwen"

    func run() async throws {
        let factory = SessionFactory()
        try EvalCLI.checkModel(factory)

        let dbPath = labelsDB ?? EvalCLI.defaultLabelsDB(for: input)
        let labelStore = try LabelStore(path: dbPath)
        let humanLabels = try labelStore.labelsByKey()

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let pinned = try EvalCLI.loadPinnedTaxonomy(input: input, reuseRunID: pinTaxonomy, taxonomyPath: taxonomyFrom)

        let opts = Organizer.Options(
            taxonomyMode: pinned != nil ? .preserve : .fresh,
            classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
            clustering: ClusteringConfig(enabled: cluster),
            embedderPreference: embedderPref,
            pinnedTaxonomy: pinned
        )

        let organizer = Organizer()
        FileHandle.standardError.write(Data("Running pipeline...\n".utf8))
        let result = try await organizer.organize(html: html, options: opts)

        let decisions = result.bookmarks.map { b in
            Classifier.Decision(
                bookmarkID: b.id,
                folder: b.assignedFolder ?? Taxonomy.unsorted,
                confidence: b.confidence ?? 0
            )
        }
        let placed = decisions.filter { $0.folder != Taxonomy.unsorted }

        FileHandle.standardError.write(Data("Judging \(placed.count) placed bookmarks against LM Studio (\(baseURL))...\n".utf8))

        let judge = LocalLLMJudge(baseURL: baseURL, model: model)
        let judgeLabels = try await judge.judgeAll(decisions: decisions, bookmarks: result.bookmarks) { done, total in
            FileHandle.standardError.write(Data("Judged \(done)/\(total)\r".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))

        let judgeByKey = Dictionary(uniqueKeysWithValues: judgeLabels.map { ($0.key, $0) })
        let (kappa, agreement, shared) = cohensKappa(human: humanLabels, judge: judgeByKey)

        let judgeAccept = judgeLabels.filter { $0.verdict == .accept }.count
        let judgeReject = judgeLabels.filter { $0.verdict == .reject }.count
        let humanAccept = humanLabels.values.filter { $0.verdict == .accept }.count
        let humanReject = humanLabels.values.filter { $0.verdict == .reject }.count

        print("Judge labels: \(judgeAccept) accept, \(judgeReject) reject")
        print("Human labels: \(humanLabels.count) (\(humanAccept) accept, \(humanReject) reject)")
        print("Shared keys: \(shared)")
        print(String(format: "Agreement: %.1f%%", agreement * 100))
        print(String(format: "Cohen's kappa: %.2f %@", kappa, kappaLabel(kappa)))

        try labelStore.upsert(judgeLabels)
        print("Judge labels written to \(dbPath)")
    }

    func kappaLabel(_ k: Double) -> String {
        switch k {
        case ..<0:    "(worse than chance)"
        case 0..<0.2: "(slight)"
        case 0.2..<0.4: "(fair)"
        case 0.4..<0.6: "(moderate)"
        case 0.6..<0.8: "(substantial)"
        case 0.8...1.0: "(almost perfect)"
        default: ""
        }
    }
}
