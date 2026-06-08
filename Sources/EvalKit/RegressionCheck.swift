import Foundation
import LazyBookmarksKit
import CryptoKit

public struct Baseline: Codable, Sendable {
    public var minYield: Double
    public var minPrecision: Double
    public var labelsHash: String

    public init(minYield: Double, minPrecision: Double, labelsHash: String) {
        self.minYield = minYield
        self.minPrecision = minPrecision
        self.labelsHash = labelsHash
    }
}

public struct RegressionReport: Sendable {
    public var pass: Bool
    public var yield: Double
    public var yieldCI: (lower: Double, upper: Double)
    public var precision: Double
    public var precisionCI: (lower: Double, upper: Double)
    public var labelsMatch: Bool
    public var report: String

    public init(
        pass: Bool,
        yield: Double,
        yieldCI: (lower: Double, upper: Double),
        precision: Double,
        precisionCI: (lower: Double, upper: Double),
        labelsMatch: Bool,
        report: String
    ) {
        self.pass = pass
        self.yield = yield
        self.yieldCI = yieldCI
        self.precision = precision
        self.precisionCI = precisionCI
        self.labelsMatch = labelsMatch
        self.report = report
    }
}

public enum RegressionCheck {

    public static func hashLabels(_ labels: [LabelKey: Label]) -> String {
        let sorted = labels.keys.sorted { ($0.bookmarkID, $0.folder) < ($1.bookmarkID, $1.folder) }
        let text = sorted.map { "\($0.bookmarkID)|\($0.folder)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func check(
        html: String,
        options: Organizer.Options,
        labels: [LabelKey: Label],
        baseline: Baseline,
        organizer: Organizer,
        bootstrapIterations: Int = 1000,
        seed: UInt64 = 42
    ) async throws -> RegressionReport {
        let currentHash = hashLabels(labels)
        let labelsMatch = currentHash == baseline.labelsHash

        let result = try await organizer.organize(html: html, options: options)
        let decisions = result.bookmarks.map { b in
            Classifier.Decision(
                bookmarkID: b.id,
                folder: b.assignedFolder ?? Taxonomy.unsorted,
                confidence: b.confidence ?? 0
            )
        }

        let m = Metrics.compute(decisions: decisions, labels: labels)

        let perItemYield: [Double] = decisions.map { d in
            guard d.folder != Taxonomy.unsorted else { return 0 }
            let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
            return labels[key]?.verdict == .accept ? 1.0 : 0.0
        }
        let perItemPrecision: [Double] = decisions.compactMap { d in
            guard d.folder != Taxonomy.unsorted else { return nil }
            let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
            return labels[key]?.verdict == .accept ? 1.0 : 0.0
        }

        let yieldCI = Metrics.bootstrapCI(perItemYield, iterations: bootstrapIterations, seed: seed)
        let precisionCI = Metrics.bootstrapCI(perItemPrecision, iterations: bootstrapIterations, seed: seed &+ 1)

        let yieldPass = yieldCI.lower >= baseline.minYield
        let precisionPass = precisionCI.lower >= baseline.minPrecision
        let pass = yieldPass && precisionPass

        var lines: [String] = []
        lines.append("Regression check: \(pass ? "PASS" : "FAIL")")
        if !labelsMatch {
            lines.append("WARNING: labels hash mismatch (labels changed since baseline)")
        }
        lines.append(String(format: "Yield:     %.1f%% [%.1f%%, %.1f%%] (min: %.1f%%) %@",
                            m.yield * 100, yieldCI.lower * 100, yieldCI.upper * 100,
                            baseline.minYield * 100, yieldPass ? "OK" : "FAIL"))
        lines.append(String(format: "Precision: %.1f%% [%.1f%%, %.1f%%] (min: %.1f%%) %@",
                            m.precision * 100, precisionCI.lower * 100, precisionCI.upper * 100,
                            baseline.minPrecision * 100, precisionPass ? "OK" : "FAIL"))
        lines.append(String(format: "Coverage:  %.1f%%", m.coverage * 100))
        lines.append(String(format: "Recall:    %.1f%%", m.recall * 100))

        return RegressionReport(
            pass: pass,
            yield: m.yield,
            yieldCI: yieldCI,
            precision: m.precision,
            precisionCI: precisionCI,
            labelsMatch: labelsMatch,
            report: lines.joined(separator: "\n")
        )
    }

    public static func captureBaseline(
        html: String,
        options: Organizer.Options,
        labels: [LabelKey: Label],
        organizer: Organizer,
        bootstrapIterations: Int = 1000,
        seed: UInt64 = 42
    ) async throws -> (baseline: Baseline, metrics: ClassificationMetrics, report: String) {
        let hash = hashLabels(labels)

        let result = try await organizer.organize(html: html, options: options)
        let decisions = result.bookmarks.map { b in
            Classifier.Decision(
                bookmarkID: b.id,
                folder: b.assignedFolder ?? Taxonomy.unsorted,
                confidence: b.confidence ?? 0
            )
        }

        let m = Metrics.compute(decisions: decisions, labels: labels)

        let perItemYield: [Double] = decisions.map { d in
            guard d.folder != Taxonomy.unsorted else { return 0 }
            let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
            return labels[key]?.verdict == .accept ? 1.0 : 0.0
        }
        let perItemPrecision: [Double] = decisions.compactMap { d in
            guard d.folder != Taxonomy.unsorted else { return nil }
            let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
            return labels[key]?.verdict == .accept ? 1.0 : 0.0
        }

        let yieldCI = Metrics.bootstrapCI(perItemYield, iterations: bootstrapIterations, seed: seed)
        let precisionCI = Metrics.bootstrapCI(perItemPrecision, iterations: bootstrapIterations, seed: seed &+ 1)

        let baseline = Baseline(
            minYield: yieldCI.lower,
            minPrecision: precisionCI.lower,
            labelsHash: hash
        )

        var lines: [String] = []
        lines.append("Baseline captured")
        lines.append(String(format: "Yield:     %.1f%% (CI lower: %.1f%%)", m.yield * 100, yieldCI.lower * 100))
        lines.append(String(format: "Precision: %.1f%% (CI lower: %.1f%%)", m.precision * 100, precisionCI.lower * 100))
        lines.append(String(format: "Coverage:  %.1f%%", m.coverage * 100))
        lines.append("Labels hash: \(hash.prefix(16))...")

        return (baseline, m, lines.joined(separator: "\n"))
    }
}
