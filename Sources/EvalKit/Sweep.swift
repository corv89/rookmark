import Foundation
import RookmarkKit

public struct SweepResult: Sendable {
    public var paramName: String
    public var paramValue: String
    public var metrics: ClassificationMetrics
    public var ci: (lower: Double, upper: Double)
    public var pairedVsBaseline: (meanDiff: Double, ci: (Double, Double), significant: Bool)?
    public var elapsedSeconds: Double

    public init(
        paramName: String,
        paramValue: String,
        metrics: ClassificationMetrics,
        ci: (lower: Double, upper: Double),
        pairedVsBaseline: (meanDiff: Double, ci: (Double, Double), significant: Bool)? = nil,
        elapsedSeconds: Double = 0
    ) {
        self.paramName = paramName
        self.paramValue = paramValue
        self.metrics = metrics
        self.ci = ci
        self.pairedVsBaseline = pairedVsBaseline
        self.elapsedSeconds = elapsedSeconds
    }
}

public enum Sweep {

    public static func run(
        html: String,
        baseOptions: Organizer.Options,
        param: String,
        values: [String],
        labels: [LabelKey: Label],
        organizer: Organizer,
        bootstrapIterations: Int = 1000,
        seed: UInt64 = 42
    ) async throws -> [SweepResult] {
        var results: [SweepResult] = []
        var baselinePerItem: [Double]?

        for value in values {
            var opts = baseOptions
            applyParam(&opts, param: param, value: value)

            let start = Date()
            let result = try await organizer.organize(html: html, options: opts)
            let elapsed = Date().timeIntervalSince(start)
            let decisions = result.bookmarks.map { b in
                Classifier.Decision(
                    bookmarkID: b.id,
                    folder: b.assignedFolder ?? Taxonomy.unsorted,
                    confidence: b.confidence ?? 0
                )
            }

            let m = Metrics.compute(decisions: decisions, labels: labels)

            let perItem: [Double] = decisions.map { d in
                guard d.folder != Taxonomy.unsorted else { return 0 }
                let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
                return labels[key]?.verdict == .accept ? 1.0 : 0.0
            }

            let ci = Metrics.bootstrapCI(perItem, iterations: bootstrapIterations, seed: seed)

            var paired: (meanDiff: Double, ci: (Double, Double), significant: Bool)?
            if let base = baselinePerItem {
                paired = Metrics.pairedBootstrapSign(a: base, b: perItem, iterations: bootstrapIterations, seed: seed &+ 1)
            } else {
                baselinePerItem = perItem
            }

            results.append(SweepResult(
                paramName: param,
                paramValue: value,
                metrics: m,
                ci: ci,
                pairedVsBaseline: paired,
                elapsedSeconds: elapsed
            ))
        }

        return results
    }

    static func applyParam(_ opts: inout Organizer.Options, param: String, value: String) {
        switch param {
        case "confidenceFloor":
            if let v = Int(value) {
                opts.classifier.confidenceFloor = v
            }
        case "batchSize":
            if let v = Int(value) {
                opts.classifier.initialBatchSize = v
            }
        case "similarityThreshold":
            if let v = Double(value) {
                opts.clustering.similarityThreshold = v
            }
        case "mergeThreshold":
            if let v = Double(value) {
                opts.clustering.mergeThreshold = v
            }
        case "maxNewFolders":
            if let v = Int(value) {
                opts.clustering.maxNewFolders = v
            }
        case "minClusterSize":
            if let v = Int(value) {
                opts.clustering.minClusterSize = v
            }
        case "minResidue":
            if let v = Int(value) {
                opts.clustering.minResidue = v
            }
        case "maxConcurrency":
            if let v = Int(value) {
                opts.classifier.maxConcurrency = v
            }
        default:
            break
        }
    }
}
