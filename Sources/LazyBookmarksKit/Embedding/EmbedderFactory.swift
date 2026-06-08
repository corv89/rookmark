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
    /// - `preferred == .sentence`: returns sentence embedder (or nil if unavailable)
    /// - `preferred == .contextual`: returns contextual embedder (or nil if unavailable)
    public static func make(preferred: Preference = .sentence) -> BookmarkEmbedder? {
        switch preferred {
        case .contextual:
            return ContextualEmbedder()
        case .sentence:
            return SentenceEmbedder()
        }
    }

    /// Async variant. Returns nil if no embedder is available.
    public static func makeAsync(preferred: Preference = .sentence) async -> BookmarkEmbedder? {
        switch preferred {
        case .contextual:
            return ContextualEmbedder()
        case .sentence:
            return SentenceEmbedder()
        }
    }
}
