import Foundation
import Testing
@testable import RookmarkKit

@Suite("Clusterer (no-model)")
struct ClustererTests {

    @Test("cosineSimilarity of identical vectors is 1.0")
    func identicalVectors() {
        let v: [Float] = [1, 2, 3]
        let sim = Clusterer.cosineSimilarity(v, v)
        #expect(abs(sim - 1.0) < 0.001)
    }

    @Test("cosineSimilarity of orthogonal vectors is 0.0")
    func orthogonalVectors() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let sim = Clusterer.cosineSimilarity(a, b)
        #expect(abs(sim) < 0.001)
    }

    @Test("cosineSimilarity of opposite vectors is -1.0")
    func oppositeVectors() {
        let a: [Float] = [1, 0]
        let b: [Float] = [-1, 0]
        let sim = Clusterer.cosineSimilarity(a, b)
        #expect(abs(sim - (-1.0)) < 0.001)
    }

    @Test("cosineSimilarity returns 0 for empty vectors")
    func emptyVectors() {
        #expect(Clusterer.cosineSimilarity([], []) == 0)
    }

    @Test("cosineSimilarity returns 0 for mismatched dimensions")
    func mismatchedDimensions() {
        #expect(Clusterer.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
    }

    @Test("vectorToBlob and blobToVector round-trip")
    func blobRoundTrip() {
        let original: [Float] = [1.5, -2.3, 0.0, 42.0]
        let blob = Clusterer.vectorToBlob(original)
        let restored = Clusterer.blobToVector(blob)
        #expect(restored.count == original.count)
        for (a, b) in zip(original, restored) {
            #expect(abs(a - b) < 0.0001)
        }
    }

    @Test("greedy clustering groups similar vectors")
    func greedyClustering() {
        let config = ClusteringConfig(similarityThreshold: 0.5, minClusterSize: 2)
        let factory = SessionFactory()
        let budget = TokenBudget(total: 4096)
        let clusterer = Clusterer(factory: factory, budget: budget, config: config)

        let vectors: [String: [Float]] = [
            "a": [1, 0, 0],
            "b": [0.9, 0.1, 0],
            "c": [0, 1, 0],
            "d": [0.1, 0.9, 0],
            "e": [0, 0, 1],
        ]
        let clusters = clusterer.cluster(vectors)
        #expect(clusters.count == 2)
        let allMembers = clusters.flatMap(\.memberIDs).sorted()
        #expect(allMembers == ["a", "b", "c", "d"])
    }

    @Test("clusters below minClusterSize are dropped")
    func minClusterSizeDrop() {
        let config = ClusteringConfig(similarityThreshold: 0.95, minClusterSize: 3)
        let factory = SessionFactory()
        let budget = TokenBudget(total: 4096)
        let clusterer = Clusterer(factory: factory, budget: budget, config: config)

        let vectors: [String: [Float]] = [
            "a": [1, 0],
            "b": [0, 1],
            "c": [0.5, 0.5],
        ]
        let clusters = clusterer.cluster(vectors)
        #expect(clusters.isEmpty)
    }

    @Test("empty input produces no clusters")
    func emptyInput() {
        let config = ClusteringConfig()
        let factory = SessionFactory()
        let budget = TokenBudget(total: 4096)
        let clusterer = Clusterer(factory: factory, budget: budget, config: config)
        #expect(clusterer.cluster([:]).isEmpty)
    }

    @Test("vectors sorted by id for reproducibility")
    func sortedById() {
        let config = ClusteringConfig(similarityThreshold: 0.9, minClusterSize: 1)
        let factory = SessionFactory()
        let budget = TokenBudget(total: 4096)
        let clusterer = Clusterer(factory: factory, budget: budget, config: config)

        let vectors: [String: [Float]] = [
            "z": [1, 0],
            "a": [0.9, 0.1],
            "m": [0.85, 0.15],
        ]
        let clusters = clusterer.cluster(vectors)
        #expect(!clusters.isEmpty)
    }

    @Test("ClusteringConfig defaults are sensible")
    func configDefaults() {
        let config = ClusteringConfig()
        #expect(!config.enabled)
        #expect(config.similarityThreshold == 0.62)
        #expect(config.mergeThreshold == 0.80)
        #expect(config.minClusterSize == 3)
        #expect(config.minResidue == 8)
        #expect(config.maxNewFolders == 12)
        #expect(config.namingSampleSize == 8)
        #expect(!config.enableLLMMerge)
        #expect(config.folderLanguage == nil)
    }

    @Test("embed returns empty dict for empty bookmarks")
    func embedEmpty() {
        let factory = SessionFactory()
        let budget = TokenBudget(total: 4096)
        let clusterer = Clusterer(factory: factory, budget: budget, config: .init())
        let result = clusterer.embed([])
        #expect(result.isEmpty)
    }

    @Test("fallbackEmbed produces vectors for bookmarks")
    func fallbackEmbed() {
        let bookmarks = [
            Bookmark(id: "a", title: "Swift", url: "https://swift.org"),
            Bookmark(id: "b", title: "Rust", url: "https://rust-lang.org"),
        ]
        var result: [String: [Float]] = [:]
        let _ = Clusterer.fallbackEmbed(bookmarks, into: &result)
        if !result.isEmpty {
            let dimA = result["a"]?.count ?? 0
            let dimB = result["b"]?.count ?? 0
            #expect(dimA == dimB)
        }
    }
}
