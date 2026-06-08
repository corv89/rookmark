import Foundation
import LazyBookmarksKit

public struct SubsampleResult: Sendable {
    public var trial: Int
    public var bookmarkCount: Int
    public var metrics: ClassificationMetrics
    public var folderNames: Set<String>

    public init(trial: Int, bookmarkCount: Int, metrics: ClassificationMetrics, folderNames: Set<String>) {
        self.trial = trial
        self.bookmarkCount = bookmarkCount
        self.metrics = metrics
        self.folderNames = folderNames
    }
}

public struct SubsampleStability: Sendable {
    public var metricMeans: ClassificationMetrics
    public var metricStddevs: ClassificationMetrics
    public var taxonomyJaccard: Double
    public var trials: [SubsampleResult]

    public init(
        metricMeans: ClassificationMetrics,
        metricStddevs: ClassificationMetrics,
        taxonomyJaccard: Double,
        trials: [SubsampleResult]
    ) {
        self.metricMeans = metricMeans
        self.metricStddevs = metricStddevs
        self.taxonomyJaccard = taxonomyJaccard
        self.trials = trials
    }
}

public enum Subsample {

    public static func stability(
        html: String,
        options: Organizer.Options,
        fraction: Double,
        trials: Int,
        organizer: Organizer,
        labels: [LabelKey: Label] = [:],
        seed: UInt64 = 42
    ) async throws -> SubsampleStability {
        var results: [SubsampleResult] = []

        for t in 0..<trials {
            let subset = subsampleHTML(html: html, fraction: fraction, seed: seed &+ UInt64(t))
            let result = try await organizer.organize(html: subset, options: options)

            let decisions = result.bookmarks.map { b in
                Classifier.Decision(
                    bookmarkID: b.id,
                    folder: b.assignedFolder ?? Taxonomy.unsorted,
                    confidence: b.confidence ?? 0
                )
            }

            let m = Metrics.compute(decisions: decisions, labels: labels)
            let folders = Set(result.taxonomy.names)
            results.append(SubsampleResult(
                trial: t,
                bookmarkCount: result.bookmarks.count,
                metrics: m,
                folderNames: folders
            ))
        }

        let means = meanMetrics(results.map(\.metrics))
        let stddevs = stddevMetrics(results.map(\.metrics), means: means)
        let jaccard = taxonomyJaccard(results.map(\.folderNames))

        return SubsampleStability(
            metricMeans: means,
            metricStddevs: stddevs,
            taxonomyJaccard: jaccard,
            trials: results
        )
    }

    static func subsampleHTML(html: String, fraction: Double, seed: UInt64) -> String {
        let parser = NetscapeBookmarkParser()
        let parsed = parser.parse(html)
        let count = max(1, Int(Double(parsed.bookmarks.count) * fraction))

        var rng = SeededRNG(seed: seed)
        var indices = Array(0..<parsed.bookmarks.count)
        for i in stride(from: indices.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            indices.swapAt(i, j)
        }
        let selected = Array(indices.prefix(count)).sorted().map { parsed.bookmarks[$0] }
        let subset = ParseResult(bookmarks: selected, existingFolders: parsed.existingFolders)

        let writer = NetscapeBookmarkWriter()
        return writer.write(subset.bookmarks)
    }

    static func taxonomyJaccard(_ folderSets: [Set<String>]) -> Double {
        guard folderSets.count >= 2 else { return 1.0 }
        var totalIntersection = 0
        var totalUnion = 0
        for i in 0..<folderSets.count {
            for j in (i+1)..<folderSets.count {
                totalIntersection += folderSets[i].intersection(folderSets[j]).count
                totalUnion += folderSets[i].union(folderSets[j]).count
            }
        }
        guard totalUnion > 0 else { return 0 }
        return Double(totalIntersection) / Double(totalUnion)
    }

    static func meanMetrics(_ metrics: [ClassificationMetrics]) -> ClassificationMetrics {
        guard !metrics.isEmpty else { return ClassificationMetrics(total: 0, placed: 0, accepted: 0, wronglyUnsorted: 0) }
        let n = Double(metrics.count)
        return ClassificationMetrics(
            total: Int(Double(metrics.map(\.total).reduce(0, +)) / n),
            placed: Int(Double(metrics.map(\.placed).reduce(0, +)) / n),
            accepted: Int(Double(metrics.map(\.accepted).reduce(0, +)) / n),
            wronglyUnsorted: Int(Double(metrics.map(\.wronglyUnsorted).reduce(0, +)) / n)
        )
    }

    static func stddevMetrics(_ metrics: [ClassificationMetrics], means: ClassificationMetrics) -> ClassificationMetrics {
        guard metrics.count > 1 else { return ClassificationMetrics(total: 0, placed: 0, accepted: 0, wronglyUnsorted: 0) }
        let n = Double(metrics.count)
        func sd(_ values: [Int], mean: Double) -> Int {
            let variance = values.map { pow(Double($0) - mean, 2) }.reduce(0, +) / n
            return Int(sqrt(variance))
        }
        return ClassificationMetrics(
            total: sd(metrics.map(\.total), mean: Double(means.total)),
            placed: sd(metrics.map(\.placed), mean: Double(means.placed)),
            accepted: sd(metrics.map(\.accepted), mean: Double(means.accepted)),
            wronglyUnsorted: sd(metrics.map(\.wronglyUnsorted), mean: Double(means.wronglyUnsorted))
        )
    }
}
