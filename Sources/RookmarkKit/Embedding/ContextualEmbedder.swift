import Foundation
@preconcurrency import NaturalLanguage

/// Wraps `NLContextualEmbedding` (macOS 14+) behind the `BookmarkEmbedder` protocol.
///
/// - 512-dim BERT-based transformer, multilingual across scripts.
/// - Input is capped at 256 tokens (defensively truncated).
/// - Per-token vectors are mean-pooled then L2-normalized.
/// - Models are cached per-script and lazy-loaded on first use.
public final class ContextualEmbedder: BookmarkEmbedder, @unchecked Sendable {
    public let modelID: String
    public let dimension: Int = 512

    private let lock = NSLock()
    private var models: [NLScript: NLContextualEmbedding] = [:]
    private var loaded: Set<NLScript> = []

    /// Maximum tokens accepted by the underlying model. Longer inputs are truncated.
    public static let maxTokens = 256

    public init?(preferredScript: NLScript = .latin) {
        guard NLContextualEmbedding(script: preferredScript) != nil else { return nil }
        self.modelID = "contextual.\(preferredScript.rawValue).v1"
    }

    /// Script detection: infer the dominant script of the text.
    public static func detectScript(_ text: String) -> NLScript {
        var scriptCounts: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.script])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .script,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            if let tag = tag {
                scriptCounts[tag.rawValue, default: 0] += 1
            }
            return true
        }
        guard let dominant = scriptCounts.max(by: { $0.value < $1.value })?.key else {
            return .latin
        }
        let script = NLScript(rawValue: dominant)
        // Fall back to Latin if no contextual model supports this script
        guard NLContextualEmbedding(script: script) != nil else { return .latin }
        return script
    }

    private func model(for script: NLScript) -> NLContextualEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let m = models[script] { return m }
        guard let m = NLContextualEmbedding(script: script) else { return nil }
        models[script] = m
        return m
    }

    public func vector(for text: String) throws -> [Float]? {
        let normalized = Self.normalizeForEmbedding(text)
        guard !normalized.isEmpty else { return nil }
        let script = Self.detectScript(normalized)
        guard let emb = model(for: script) else { return nil }

        // load() is required before embeddingResult; throws on first-run compilation.
        lock.lock()
        let alreadyLoaded = loaded.contains(script)
        lock.unlock()
        if !alreadyLoaded {
            do {
                try emb.load()
                lock.lock()
                loaded.insert(script)
                lock.unlock()
            } catch {
                return nil
            }
        }

        guard emb.hasAvailableAssets else { return nil }

        do {
            let result = try emb.embeddingResult(for: normalized, language: .undetermined)
            var sum = Array(repeating: 0.0, count: dimension)
            var count = 0
            let range = normalized.startIndex..<normalized.endIndex
            result.enumerateTokenVectors(in: range) { vec, _ in
                count += 1
                for (i, v) in vec.enumerated() where i < dimension {
                    sum[i] += v
                }
                return count < Self.maxTokens
            }
            guard count > 0 else { return nil }
            let mean = sum.map { Float($0) / Float(count) }
            return L2Normalize(mean)
        } catch {
            return nil
        }
    }

    /// Strips site boilerplate and domain suffixes from a bookmark title.
    /// Preserves case (contextual models are cased).
    public static func normalizeForEmbedding(_ text: String) -> String {
        var s = text
        // Strip common site boilerplate suffixes
        let separators = [" | ", " — ", " – ", " - ", " · ", " • ", " / "]
        for sep in separators {
            if let idx = s.range(of: sep, options: .backwards) {
                let suffix = String(s[idx.upperBound...])
                // Only strip if suffix looks like a site name (no spaces or short)
                if !suffix.contains(" ") || suffix.count < 20 {
                    s = String(s[..<idx.lowerBound])
                }
            }
        }
        // Strip trailing " (2024)" or " (2024-01-01)" year markers
        if let match = s.range(of: #" \(\d{4}(-\d{2}(-\d{2})?)?\)$"#, options: .regularExpression) {
            s = String(s[..<match.lowerBound])
        }
        // Strip trailing " - SiteName" or " – SiteName" (case-insensitive)
        if let match = s.range(of: #"\s+[-–—]\s+\S+$"#, options: .regularExpression) {
            let suffix = String(s[match.upperBound...])
            if suffix.count < 25 {
                s = String(s[..<match.lowerBound])
            }
        }
        // Collapse whitespace and trim
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    /// Unloads all cached models to free memory.
    public func unload() {
        lock.lock()
        defer { lock.unlock() }
        for m in models.values { m.unload() }
        models.removeAll()
        loaded.removeAll()
    }

    /// Reports whether the requested script's assets are available.
    public func hasAssets(for script: NLScript) -> Bool {
        model(for: script)?.hasAvailableAssets ?? false
    }

    /// Async wrapper around the completion-based `requestAssets`.
    /// Returns `true` if assets are available for the given script after the call.
    public func requestAssetsAsync(for script: NLScript = .latin, completion: @escaping @Sendable (Bool) -> Void) {
        guard let m = model(for: script) else {
            completion(false)
            return
        }
        m.requestAssets { _, error in
            completion(error == nil && m.hasAvailableAssets)
        }
    }
}
