import Foundation
@preconcurrency import NaturalLanguage

/// Selects the best available `BookmarkEmbedder`.
///
/// Selection order:
///   1. Explicit `--embedder` override
///   2. `ContextualEmbedder` if assets available (or downloadable & permitted)
///   3. `SentenceEmbedder`
///   4. `nil` (Clusterer then skips embedding)
public enum EmbedderFactory {

    public enum Preference: String, Sendable {
        case auto
        case contextual
        case sentence
    }

    /// Per-embedder-family default thresholds, tuned on the 720-set.
    public struct Thresholds: Sendable {
        public var similarity: Double
        public var merge: Double
    }

    public static func defaultThresholds(for modelID: String) -> Thresholds {
        if modelID.hasPrefix("contextual") {
            // Contextual embeddings have a tighter cosine distribution;
            // lower threshold needed to achieve comparable groupings.
            return Thresholds(similarity: 0.50, merge: 0.82)
        }
        // Sentence embeddings: M9-tuned values.
        return Thresholds(similarity: 0.62, merge: 0.80)
    }

    /// Creates the best available embedder synchronously.
    ///
    /// - `preferred == .contextual`: tries contextual, returns nil if unavailable
    /// - `preferred == .sentence`: always returns sentence embedder (or nil)
    /// - `preferred == .auto`: contextual → sentence → nil
    public static func makeBest(preferred: Preference = .auto) -> BookmarkEmbedder? {
        switch preferred {
        case .contextual:
            return ContextualEmbedder()
        case .sentence:
            return SentenceEmbedder()
        case .auto:
            if let c = ContextualEmbedder(), c.hasAssets(for: .latin) {
                return c
            }
            return SentenceEmbedder()
        }
    }

    /// Async variant that attempts to download assets for contextual if needed.
    /// Returns nil if no embedder is available.
    public static func makeBestAsync(preferred: Preference = .auto) async -> BookmarkEmbedder? {
        switch preferred {
        case .contextual:
            return ContextualEmbedder()
        case .sentence:
            return SentenceEmbedder()
        case .auto:
            if let c = ContextualEmbedder() {
                if c.hasAssets(for: .latin) { return c }
                // Try async asset request
                let got = await withCheckedContinuation { cont in
                    c.requestAssetsAsync(for: .latin) { success in
                        cont.resume(returning: success)
                    }
                }
                if got { return c }
            }
            return SentenceEmbedder()
        }
    }
}
