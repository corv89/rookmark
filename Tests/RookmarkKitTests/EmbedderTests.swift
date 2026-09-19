import Foundation
import Testing
@testable import RookmarkKit

@Suite("L2Normalize")
struct L2NormalizeTests {

    @Test("normalizes unit vector to itself")
    func unitVector() {
        let v: [Float] = [1, 0, 0]
        let n = L2Normalize(v)
        #expect(n != nil)
        #expect(abs(n![0] - 1.0) < 0.0001)
        #expect(abs(n![1]) < 0.0001)
    }

    @Test("normalizes arbitrary vector to unit length")
    func arbitraryVector() {
        let v: [Float] = [3, 4]
        let n = L2Normalize(v)
        #expect(n != nil)
        var sum: Float = 0
        for x in n! { sum += x * x }
        #expect(abs(sum - 1.0) < 0.0001)
    }

    @Test("zero vector returns nil")
    func zeroVector() {
        let v: [Float] = [0, 0, 0]
        #expect(L2Normalize(v) == nil)
    }

    @Test("negative values handled correctly")
    func negativeValues() {
        let v: [Float] = [-3, 4]
        let n = L2Normalize(v)
        #expect(n != nil)
        var sum: Float = 0
        for x in n! { sum += x * x }
        #expect(abs(sum - 1.0) < 0.0001)
    }
}

@Suite("ContextualEmbedder.normalizeForEmbedding")
struct NormalizeForEmbeddingTests {

    @Test("strips site name suffix after pipe")
    func stripsPipe() {
        let result = ContextualEmbedder.normalizeForEmbedding("Learn Swift | Apple Developer")
        #expect(result == "Learn Swift")
    }

    @Test("strips dash suffix")
    func stripsDash() {
        let result = ContextualEmbedder.normalizeForEmbedding("Article Title - Medium")
        #expect(result == "Article Title")
    }

    @Test("strips trailing year marker")
    func stripsYear() {
        let result = ContextualEmbedder.normalizeForEmbedding("Some Article (2024)")
        #expect(result == "Some Article")
    }

    @Test("strips trailing date marker")
    func stripsDate() {
        let result = ContextualEmbedder.normalizeForEmbedding("Some Article (2024-01-15)")
        #expect(result == "Some Article")
    }

    @Test("preserves case")
    func preservesCase() {
        let result = ContextualEmbedder.normalizeForEmbedding("My Title Here")
        #expect(result == "My Title Here")
    }

    @Test("collapses whitespace")
    func collapsesWhitespace() {
        let result = ContextualEmbedder.normalizeForEmbedding("  hello   world  ")
        #expect(result == "hello world")
    }

    @Test("does not strip long suffixes")
    func keepsLongSuffixes() {
        // Suffix has spaces and is long — probably part of the title
        let result = ContextualEmbedder.normalizeForEmbedding("Introduction to Machine Learning with Neural Networks")
        #expect(result.contains("Machine Learning"))
    }
}

@Suite("SentenceEmbedder fallback")
struct SentenceEmbedderTests {

    @Test("sentence embedder is available on this system")
    func available() {
        let emb = SentenceEmbedder()
        #expect(emb != nil)
        #expect(emb?.dimension ?? 0 > 0)
    }

    @Test("sentence embedder returns normalized vector")
    func returnsNormalized() throws {
        guard let emb = SentenceEmbedder() else {
            Issue.record("SentenceEmbedder unavailable")
            return
        }
        let v = try emb.vector(for: "Hello world")
        #expect(v != nil)
        if let v = v {
            var sum: Float = 0
            for x in v { sum += x * x }
            #expect(abs(sum - 1.0) < 0.01)
        }
    }

    @Test("modelID starts with sentence")
    func modelID() {
        guard let emb = SentenceEmbedder() else { return }
        #expect(emb.modelID.hasPrefix("sentence."))
    }
}

@Suite("FakeEmbedder protocol conformance")
struct FakeEmbedderTests {

    struct FakeEmbedder: BookmarkEmbedder {
        let modelID: String = "fake.v1"
        let dimension: Int = 3
        func vector(for text: String) throws -> [Float]? {
            guard !text.isEmpty else { return nil }
            return [1, 0, 0]
        }
    }

    @Test("fake embedder conforms to protocol")
    func conforms() throws {
        let e = FakeEmbedder()
        let v = try e.vector(for: "anything")
        #expect(v?.count == 3)
        #expect(e.modelID == "fake.v1")
        #expect(e.dimension == 3)
    }

    @Test("fake embedder returns nil for empty")
    func emptyReturnsNil() throws {
        let e = FakeEmbedder()
        #expect(try e.vector(for: "") == nil)
    }
}

@Suite("ContextualEmbedder script detection")
struct ScriptDetectionTests {

    @Test("detects Latin script")
    func latin() {
        let script = ContextualEmbedder.detectScript("Hello world this is English")
        #expect(script == .latin)
    }

    @Test("defaults to Latin for unknown")
    func fallback() {
        // Empty string should default to Latin
        let script = ContextualEmbedder.detectScript("")
        #expect(script == .latin)
    }
}

@Suite("Cache invalidation by modelID")
struct CacheInvalidationTests {

    @Test("different embedder types produce different modelIDs")
    func differentModelIDs() {
        guard let sent = SentenceEmbedder() else { return }
        let ctxID = "contextual.latin.v1"
        #expect(sent.modelID != ctxID)
        #expect(sent.modelID.hasPrefix("sentence."))
    }
}
