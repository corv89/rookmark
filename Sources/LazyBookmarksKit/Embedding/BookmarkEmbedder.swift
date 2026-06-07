import Foundation

/// Abstracts over embedding backends so `Clusterer` is backend-agnostic.
///
/// Implementations must produce L2-normalized vectors of fixed dimension.
/// `modelID` is used for cache invalidation — changing the embedder invalidates
/// all cached vectors in the store.
public protocol BookmarkEmbedder: Sendable {
    /// Stable identifier for the embedding model (e.g. "contextual.latin.v1").
    /// Changing the embedder recomputes all cached vectors.
    var modelID: String { get }

    /// Dimensionality of the output vectors.
    var dimension: Int { get }

    /// Embed a single piece of text. Returns `nil` if the text cannot be
    /// embedded (e.g. empty, or unsupported language). Returned vectors must
    /// be L2-normalized so that cosine similarity equals dot product.
    func vector(for text: String) throws -> [Float]?
}
