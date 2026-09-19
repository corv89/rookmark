import Foundation
@preconcurrency import NaturalLanguage

/// Selects the `BookmarkEmbedder` based on explicit preference.
///
/// Selection:
///   - `.sentence`: always returns `SentenceEmbedder` (the default)
///   - `.contextual`: returns `ContextualEmbedder` if available, else throws
public enum EmbedderFactory {

    public enum Preference: String, Sendable {
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
            return Thresholds(similarity: 0.50, merge: 0.82)
        }
        return Thresholds(similarity: 0.62, merge: 0.80)
    }

    /// Creates an embedder synchronously.
    ///
    /// - `preferred == .contextual`: returns contextual embedder (or nil if unavailable)
    /// - `preferred == .sentence`: returns sentence embedder (or nil if unavailable)
    public static func make(preferred: Preference = .contextual) -> BookmarkEmbedder? {
        switch preferred {
        case .contextual:
            return ContextualEmbedder()
        case .sentence:
            return SentenceEmbedder()
        }
    }

    /// Async variant. Returns nil if no embedder is available.
    public static func makeAsync(preferred: Preference = .contextual) async -> BookmarkEmbedder? {
        switch preferred {
        case .contextual:
            return ContextualEmbedder()
        case .sentence:
            return SentenceEmbedder()
        }
    }

    /// Whether the contextual embedding assets are available for the given script.
    public static func hasContextualAssets(for script: NLScript = .latin) -> Bool {
        guard let emb = NLContextualEmbedding(script: script) else { return false }
        return emb.hasAvailableAssets
    }

    /// Request contextual embedding asset download. Calls back with success.
    public static func requestContextualAssets(
        for script: NLScript = .latin,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let emb = NLContextualEmbedding(script: script) else {
            completion(false)
            return
        }
        emb.requestAssets { _, error in
            completion(error == nil && emb.hasAvailableAssets)
        }
    }
}
