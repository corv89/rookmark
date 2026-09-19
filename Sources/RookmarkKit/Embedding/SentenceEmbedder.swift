import Foundation
@preconcurrency import NaturalLanguage

/// Wraps `NLEmbedding.sentenceEmbedding` behind the `BookmarkEmbedder` protocol.
/// Used as the fallback when contextual embedding is unavailable.
public struct SentenceEmbedder: BookmarkEmbedder, @unchecked Sendable {
    public let modelID: String
    public let dimension: Int

    private let embedding: NLEmbedding
    private let fallback: NLEmbedding?

    public init?(language: NLLanguage = .english) {
        guard let emb = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.embedding = emb
        self.dimension = emb.dimension
        self.modelID = "sentence.\(language.rawValue).v1"
        self.fallback = NLEmbedding.wordEmbedding(for: language)
    }

    public func vector(for text: String) throws -> [Float]? {
        if let vec = embedding.vector(for: text) {
            return L2Normalize(vec.map { Float($0) })
        }
        // Fallback: average word embeddings
        guard let wordEmb = fallback else { return nil }
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var avg = Array(repeating: Float(0), count: wordEmb.dimension)
        var count = 0
        for w in words {
            if let vec = wordEmb.vector(for: w) {
                for (i, v) in vec.enumerated() { avg[i] += Float(v) }
                count += 1
            }
        }
        guard count > 0 else { return nil }
        for i in avg.indices { avg[i] /= Float(count) }
        return L2Normalize(avg)
    }
}

/// L2-normalizes a vector in place. Returns nil if the norm is zero.
public func L2Normalize(_ v: [Float]) -> [Float]? {
    var norm: Float = 0
    for x in v { norm += x * x }
    norm = sqrt(norm)
    guard norm > 0 else { return nil }
    return v.map { $0 / norm }
}
