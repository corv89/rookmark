import Testing
@testable import EvalKit
import RookmarkKit

@Suite("ClassificationMetrics")
struct ClassificationMetricsTests {

    @Test("compute from hand-computed fixture")
    func basicCompute() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: "News", confidence: 80),
            Classifier.Decision(bookmarkID: "2", folder: "News", confidence: 75),
            Classifier.Decision(bookmarkID: "3", folder: "Cooking", confidence: 60),
            Classifier.Decision(bookmarkID: "4", folder: "Cooking", confidence: 50),
            Classifier.Decision(bookmarkID: "5", folder: Taxonomy.unsorted, confidence: 30),
            Classifier.Decision(bookmarkID: "6", folder: Taxonomy.unsorted, confidence: 20, modelChosenFolder: "News"),
            Classifier.Decision(bookmarkID: "7", folder: Taxonomy.unsorted, confidence: 10, modelChosenFolder: "Cooking"),
            Classifier.Decision(bookmarkID: "8", folder: Taxonomy.unsorted, confidence: 5),
            Classifier.Decision(bookmarkID: "9", folder: "News", confidence: 90),
            Classifier.Decision(bookmarkID: "10", folder: "Cooking", confidence: 85),
        ]

        let labels: [LabelKey: Label] = [
            LabelKey(bookmarkID: "1", folder: "News"): .init(bookmarkID: "1", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "2", folder: "News"): .init(bookmarkID: "2", folder: "News", verdict: .reject),
            LabelKey(bookmarkID: "3", folder: "Cooking"): .init(bookmarkID: "3", folder: "Cooking", verdict: .accept),
            LabelKey(bookmarkID: "4", folder: "Cooking"): .init(bookmarkID: "4", folder: "Cooking", verdict: .accept),
            LabelKey(bookmarkID: "6", folder: "News"): .init(bookmarkID: "6", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "7", folder: "Cooking"): .init(bookmarkID: "7", folder: "Cooking", verdict: .reject),
            LabelKey(bookmarkID: "9", folder: "News"): .init(bookmarkID: "9", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "10", folder: "Cooking"): .init(bookmarkID: "10", folder: "Cooking", verdict: .accept),
        ]

        let m = Metrics.compute(decisions: decisions, labels: labels)
        #expect(m.total == 10)
        #expect(m.placed == 6)
        #expect(m.accepted == 5)
        #expect(m.wronglyUnsorted == 1)

        #expect(abs(m.coverage - 0.6) < 0.001)
        #expect(abs(m.precision - 5.0/6.0) < 0.001)
        #expect(abs(m.yield - 0.5) < 0.001)
        #expect(abs(m.recall - 5.0/6.0) < 0.001)
    }

    @Test("compute with no labels returns zero accepted")
    func noLabels() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: "News", confidence: 80),
            Classifier.Decision(bookmarkID: "2", folder: "News", confidence: 70),
        ]
        let m = Metrics.compute(decisions: decisions, labels: [:])
        #expect(m.total == 2)
        #expect(m.placed == 2)
        #expect(m.accepted == 0)
        #expect(m.yield == 0)
    }

    @Test("compute with all unsorted and no modelChosenFolder")
    func allUnsorted() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: Taxonomy.unsorted, confidence: 0),
            Classifier.Decision(bookmarkID: "2", folder: Taxonomy.unsorted, confidence: 0),
        ]
        let m = Metrics.compute(decisions: decisions, labels: [:])
        #expect(m.placed == 0)
        #expect(m.wronglyUnsorted == 0)
        #expect(m.precision == 0)
        #expect(m.recall == 0)
    }

    @Test("empty decisions")
    func empty() {
        let m = Metrics.compute(decisions: [], labels: [:])
        #expect(m.total == 0)
        #expect(m.coverage == 0)
        #expect(m.precision == 0)
        #expect(m.yield == 0)
    }
}

@Suite("Bootstrap CI")
struct BootstrapTests {

    @Test("deterministic seed produces same interval")
    func deterministicSeed() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        let ci1 = Metrics.bootstrapCI(values, seed: 42)
        let ci2 = Metrics.bootstrapCI(values, seed: 42)
        #expect(ci1.lower == ci2.lower)
        #expect(ci1.upper == ci2.upper)
    }

    @Test("different seeds produce different intervals")
    func differentSeeds() {
        let values = (1...100).map { Double($0) }
        let ci1 = Metrics.bootstrapCI(values, iterations: 500, seed: 1)
        let ci2 = Metrics.bootstrapCI(values, iterations: 500, seed: 999)
        #expect(ci1.lower != ci2.lower || ci1.upper != ci2.upper)
    }

    @Test("CI brackets the sample mean for symmetric data")
    func bracketsMean() {
        let values = (1...100).map { Double($0) }
        let ci = Metrics.bootstrapCI(values, iterations: 1000, seed: 42)
        let sampleMean = values.reduce(0, +) / Double(values.count)
        #expect(ci.lower < sampleMean)
        #expect(ci.upper > sampleMean)
    }

    @Test("empty values return (0, 0)")
    func emptyValues() {
        let ci = Metrics.bootstrapCI([], seed: 42)
        #expect(ci.lower == 0)
        #expect(ci.upper == 0)
    }

    @Test("single value returns that value for both bounds")
    func singleValue() {
        let ci = Metrics.bootstrapCI([5.0], seed: 42)
        #expect(ci.lower == 5.0)
        #expect(ci.upper == 5.0)
    }
}

@Suite("Paired bootstrap sign")
struct PairedBootstrapTests {

    @Test("significantly different distributions report significant=true")
    func significantDifference() {
        let a = (1...50).map { Double($0) + 10 }
        let b = (1...50).map { Double($0) }
        let result = Metrics.pairedBootstrapSign(a: a, b: b, iterations: 1000, seed: 42)
        #expect(result.significant)
        #expect(result.meanDiff > 0)
    }

    @Test("identical distributions report significant=false")
    func noDifference() {
        let a = [1.0, 2.0, 3.0, 4.0, 5.0]
        let result = Metrics.pairedBootstrapSign(a: a, b: a, iterations: 1000, seed: 42)
        #expect(result.meanDiff == 0)
        #expect(!result.significant)
    }

    @Test("mismatched lengths return zero")
    func mismatchedLengths() {
        let result = Metrics.pairedBootstrapSign(a: [1.0, 2.0], b: [1.0], seed: 42)
        #expect(result.meanDiff == 0)
        #expect(!result.significant)
    }
}

@Suite("Structural metrics")
struct StructuralMetricsTests {

    @Test("identical vectors in one folder produce coherence 1.0")
    func perfectCoherence() {
        let vec: [Float] = [1.0, 0.0, 0.0]
        let vectors = ["a": vec, "b": vec, "c": vec]
        let assignments = ["a": "News", "b": "News", "c": "News"]
        let m = StructuralMetrics.compute(vectors: vectors, assignments: assignments)
        #expect(abs(m.coherence - 1.0) < 0.001)
        #expect(m.singletonRate == 0)
    }

    @Test("orthogonal centroids produce distinctness ~1.0")
    func perfectDistinctness() {
        let vectors: [String: [Float]] = [
            "a": [1.0, 0.0, 0.0],
            "b": [0.0, 1.0, 0.0],
            "c": [0.0, 0.0, 1.0],
        ]
        let assignments = ["a": "A", "b": "B", "c": "C"]
        let m = StructuralMetrics.compute(vectors: vectors, assignments: assignments)
        #expect(m.distinctness > 0.99)
        #expect(abs(m.singletonRate - 1.0) < 0.001)
    }

    @Test("empty input returns zero metrics")
    func emptyInput() {
        let m = StructuralMetrics.compute(vectors: [:], assignments: [:])
        #expect(m.coherence == 0)
        #expect(m.distinctness == 0)
        #expect(m.singletonRate == 0)
        #expect(m.sizeStddev == 0)
    }

    @Test("singleton rate is 1.0 when all folders have one item")
    func allSingletons() {
        let vectors: [String: [Float]] = [
            "a": [1.0, 0.0],
            "b": [0.0, 1.0],
        ]
        let assignments = ["a": "A", "b": "B"]
        let m = StructuralMetrics.compute(vectors: vectors, assignments: assignments)
        #expect(abs(m.singletonRate - 1.0) < 0.001)
    }

    @Test("size stddev is 0 for uniform folder sizes")
    func uniformSizes() {
        let vectors: [String: [Float]] = [
            "a1": [1.0, 0.0], "a2": [0.9, 0.1],
            "b1": [0.0, 1.0], "b2": [0.1, 0.9],
        ]
        let assignments = ["a1": "A", "a2": "A", "b1": "B", "b2": "B"]
        let m = StructuralMetrics.compute(vectors: vectors, assignments: assignments)
        #expect(m.sizeStddev < 0.001)
    }
}
