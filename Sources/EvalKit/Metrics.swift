import Foundation
import RookmarkKit

public struct ClassificationMetrics: Sendable, Equatable {
    public var total: Int
    public var placed: Int
    public var accepted: Int
    public var wronglyUnsorted: Int

    public var coverage: Double {
        total > 0 ? Double(placed) / Double(total) : 0
    }

    public var precision: Double {
        placed > 0 ? Double(accepted) / Double(placed) : 0
    }

    public var yield: Double {
        total > 0 ? Double(accepted) / Double(total) : 0
    }

    public var recall: Double {
        let denom = accepted + wronglyUnsorted
        return denom > 0 ? Double(accepted) / Double(denom) : 0
    }

    public init(total: Int, placed: Int, accepted: Int, wronglyUnsorted: Int) {
        self.total = total
        self.placed = placed
        self.accepted = accepted
        self.wronglyUnsorted = wronglyUnsorted
    }
}

public struct TaxonomyMetrics: Sendable, Equatable {
    public var coherence: Double
    public var distinctness: Double
    public var singletonRate: Double
    public var sizeStddev: Double

    public init(coherence: Double, distinctness: Double, singletonRate: Double, sizeStddev: Double) {
        self.coherence = coherence
        self.distinctness = distinctness
        self.singletonRate = singletonRate
        self.sizeStddev = sizeStddev
    }
}

public enum Metrics {

    public static func compute(
        decisions: [Classifier.Decision],
        labels: [LabelKey: Label]
    ) -> ClassificationMetrics {
        let total = decisions.count
        var placed = 0
        var accepted = 0
        var wronglyUnsorted = 0

        for d in decisions {
            let isPlaced = d.folder != Taxonomy.unsorted
            if isPlaced {
                placed += 1
                let key = LabelKey(bookmarkID: d.bookmarkID, folder: d.folder)
                if let label = labels[key], label.verdict == .accept {
                    accepted += 1
                }
            } else {
                if let chosen = d.modelChosenFolder, chosen != Taxonomy.unsorted {
                    let key = LabelKey(bookmarkID: d.bookmarkID, folder: chosen)
                    if let label = labels[key], label.verdict == .accept {
                        wronglyUnsorted += 1
                    }
                }
            }
        }

        return ClassificationMetrics(
            total: total,
            placed: placed,
            accepted: accepted,
            wronglyUnsorted: wronglyUnsorted
        )
    }

    public static func bootstrapCI(
        _ values: [Double],
        confidence: Double = 0.95,
        iterations: Int = 1000,
        seed: UInt64
    ) -> (lower: Double, upper: Double) {
        guard !values.isEmpty, iterations > 0 else { return (0, 0) }

        var rng = SeededRNG(seed: seed)
        var means: [Double] = []
        means.reserveCapacity(iterations)

        for _ in 0..<iterations {
            var sum = 0.0
            for _ in 0..<values.count {
                let idx = Int(rng.next() % UInt64(values.count))
                sum += values[idx]
            }
            means.append(sum / Double(values.count))
        }

        means.sort()
        let tail = (1.0 - confidence) / 2.0
        let lo = Int((tail * Double(iterations)).rounded(.down))
        let hi = Int(((1.0 - tail) * Double(iterations)).rounded(.down)) - 1
        return (
            means[max(0, lo)],
            means[min(means.count - 1, hi)]
        )
    }

    public static func pairedBootstrapSign(
        a: [Double],
        b: [Double],
        iterations: Int = 1000,
        seed: UInt64
    ) -> (meanDiff: Double, ci: (Double, Double), significant: Bool) {
        guard a.count == b.count, !a.isEmpty else {
            return (0, (0, 0), false)
        }

        let diffs = zip(a, b).map { $0.0 - $0.1 }
        let meanDiff = diffs.reduce(0, +) / Double(diffs.count)

        var rng = SeededRNG(seed: seed)
        var meanDiffs: [Double] = []
        meanDiffs.reserveCapacity(iterations)

        for _ in 0..<iterations {
            var sum = 0.0
            for _ in 0..<diffs.count {
                let idx = Int(rng.next() % UInt64(diffs.count))
                sum += diffs[idx]
            }
            meanDiffs.append(sum / Double(diffs.count))
        }

        meanDiffs.sort()
        let lo = Int(0.025 * Double(iterations))
        let hi = Int(0.975 * Double(iterations)) - 1
        let ciLo = meanDiffs[max(0, lo)]
        let ciHi = meanDiffs[min(meanDiffs.count - 1, hi)]

        let significant = (ciLo > 0 && ciHi > 0) || (ciLo < 0 && ciHi < 0)
        return (meanDiff, (ciLo, ciHi), significant)
    }
}

public enum StructuralMetrics {

    public static func compute(
        vectors: [String: [Float]],
        assignments: [String: String]
    ) -> TaxonomyMetrics {
        var folderVectors: [String: [[Float]]] = [:]
        for (id, folder) in assignments {
            guard let vec = vectors[id] else { continue }
            folderVectors[folder, default: []].append(vec)
        }

        guard !folderVectors.isEmpty else {
            return TaxonomyMetrics(coherence: 0, distinctness: 0, singletonRate: 0, sizeStddev: 0)
        }

        var intraCosines: [Double] = []
        var centroids: [[Float]] = []
        var sizes: [Double] = []
        var singletons = 0

        for (_, vecs) in folderVectors {
            sizes.append(Double(vecs.count))
            if vecs.count == 1 { singletons += 1 }
            let centroid = meanVector(vecs)
            centroids.append(centroid)

            if vecs.count >= 2 {
                for v in vecs {
                    let sim = cosine(v, centroid)
                    intraCosines.append(sim)
                }
            }
        }

        let coherence = intraCosines.isEmpty ? 0 : intraCosines.reduce(0, +) / Double(intraCosines.count)

        var nnSims: [Double] = []
        for i in 0..<centroids.count {
            var bestSim = -1.0
            for j in 0..<centroids.count where j != i {
                let sim = cosine(centroids[i], centroids[j])
                if sim > bestSim { bestSim = sim }
            }
            if centroids.count > 1 { nnSims.append(bestSim) }
        }
        let meanNNSim = nnSims.isEmpty ? 0 : nnSims.reduce(0, +) / Double(nnSims.count)
        let distinctness = 1.0 - meanNNSim

        let singletonRate = Double(singletons) / Double(folderVectors.count)

        let meanSize = sizes.reduce(0, +) / Double(sizes.count)
        let variance = sizes.map { ($0 - meanSize) * ($0 - meanSize) }.reduce(0, +) / Double(sizes.count)
        let sizeStddev = sqrt(variance)

        return TaxonomyMetrics(
            coherence: coherence,
            distinctness: distinctness,
            singletonRate: singletonRate,
            sizeStddev: sizeStddev
        )
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return Double(dot / denom)
    }

    static func meanVector(_ vecs: [[Float]]) -> [Float] {
        guard let first = vecs.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vecs {
            for i in 0..<min(sum.count, v.count) {
                sum[i] += v[i]
            }
        }
        let n = Float(vecs.count)
        return sum.map { $0 / n }
    }
}

struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
