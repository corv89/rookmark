import Foundation
import FoundationModels
import NaturalLanguage

/// Phase 1: produce the flat topic taxonomy the classifier will target.
///
/// Modes:
///  • `.preserve` — seed from `existingFolders`, optionally augment via the model.
///  • `.fresh`    — ignore existing structure, generate from a sample of bookmarks.
///
/// Constraint: the rendered taxonomy must fit comfortably inside the input budget
/// (it is prepended to *every* classification prompt). If too many folders are
/// generated/seeded, cap and/or run the optional merge-similar pass.
public struct TaxonomyBuilder: Sendable {

    public enum Mode: Sendable { case preserve, fresh }

    private let factory: SessionFactory
    private let budget: TokenBudget

    public init(factory: SessionFactory, budget: TokenBudget) {
        self.factory = factory
        self.budget = budget
    }

    static let maxFolders = 20

    public func build(from parse: ParseResult, mode: Mode, folderLanguage: String? = nil) async throws -> Taxonomy {
        let folders: [Taxonomy.Folder]
        switch mode {
        case .preserve where !parse.existingFolders.isEmpty:
            folders = parse.existingFolders.prefix(Self.maxFolders).map {
                Taxonomy.Folder(name: FolderNameSanitizer.sanitize($0), rationale: "")
            }

        default:
            let sample = Array(parse.bookmarks.prefix(40))
            let lines = sample.map { "\($0.title.isEmpty ? "(untitled)" : $0.title) | \($0.domain)" }
                .joined(separator: "\n")

            let langInstruction: String
            if let lang = folderLanguage {
                langInstruction = " Name all folders in \(lang) regardless of the language of the bookmarks."
            } else {
                langInstruction = ""
            }

            let prompt = """
            Given these bookmark titles and domains, propose 8–20 broad, non-overlapping \
            topic folders that would organize them well:\(langInstruction)

            \(lines)
            """

            let session = factory.makeSession(instructions: """
            You propose folder structures for bookmark collections. Generate a flat set of \
            8–20 topic folders. Each folder has a short Title Case name (1–3 words) and a \
            one-sentence description of what belongs there.
            """)

            let generated = try await session.respond(
                to: prompt, generating: GeneratedTaxonomy.self
            ).content

            folders = generated.folders.prefix(Self.maxFolders).map {
                Taxonomy.Folder(name: FolderNameSanitizer.sanitize($0.name), rationale: $0.rationale)
            }
        }
        let cleaned = folders.filter { !$0.name.isEmpty }
        let deduped = FolderNameSanitizer.deduplicate(cleaned)
        return Taxonomy(folders: Array(deduped))
    }

    public func mergeSimilar(_ taxonomy: Taxonomy) async throws -> Taxonomy {
        taxonomy
    }

    /// Prunes a taxonomy to at most `cap` folders by repeatedly merging the two
    /// semantically closest folders (by name+rationale embedding). When no pair
    /// remains above `mergeThreshold`, falls back to dropping the smallest folder
    /// and routing its members to the nearest surviving folder (or Unsorted).
    ///
    /// Returns the pruned taxonomy with `folders.count ≤ cap`.
    public static func pruneToCap(
        _ taxonomy: Taxonomy,
        cap: Int,
        mergeThreshold: Double = 0.80
    ) -> Taxonomy {
        guard cap >= 0, taxonomy.folders.count > cap else { return taxonomy }
        guard cap > 0 else { return Taxonomy(folders: []) }

        var folders = taxonomy.folders
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            // No embedding available: drop smallest folders until at cap.
            let sorted = folders.sorted { $0.name < $1.name }
            return Taxonomy(folders: Array(sorted.prefix(cap)))
        }

        // Compute vectors for all folders.
        var vectors: [(index: Int, name: String, vector: [Float])] = []
        for (i, f) in folders.enumerated() {
            let text = "\(f.name) \(f.rationale)"
            if let vec = embedding.vector(for: text) {
                vectors.append((i, f.name, vec.map { Float($0) }))
            }
        }

        // Greedy merge: repeatedly merge the closest pair above threshold.
        while folders.count > cap && vectors.count >= 2 {
            var bestI = -1, bestJ = -1
            var bestSim: Float = -1

            for i in 0..<vectors.count {
                for j in (i+1)..<vectors.count {
                    let sim = Clusterer.cosineSimilarity(vectors[i].vector, vectors[j].vector)
                    if sim > bestSim {
                        bestSim = sim
                        bestI = i
                        bestJ = j
                    }
                }
            }

            guard bestI >= 0, bestJ >= 0 else { break }

            if bestSim >= Float(mergeThreshold) {
                // Merge: keep the folder with the longer name (more specific), drop the other.
                let keepIdx = folders[vectors[bestI].index].name.count >= folders[vectors[bestJ].index].name.count ? bestI : bestJ
                let dropIdx = keepIdx == bestI ? bestJ : bestI

                // Remove the dropped folder and its vector.
                let dropFolderIdx = vectors[dropIdx].index
                folders.remove(at: dropFolderIdx)

                // Rebuild vectors with updated indices.
                vectors = vectors.compactMap { v in
                    if v.index == dropFolderIdx { return nil }
                    let newIdx = v.index > dropFolderIdx ? v.index - 1 : v.index
                    return (newIdx, v.name, v.vector)
                }
            } else {
                // Below threshold: drop the smallest folder (by name length as proxy).
                let dropIdx = folders[vectors[bestI].index].name.count <= folders[vectors[bestJ].index].name.count ? bestI : bestJ
                let dropFolderIdx = vectors[dropIdx].index
                folders.remove(at: dropFolderIdx)

                vectors = vectors.compactMap { v in
                    if v.index == dropFolderIdx { return nil }
                    let newIdx = v.index > dropFolderIdx ? v.index - 1 : v.index
                    return (newIdx, v.name, v.vector)
                }
            }
        }

        return Taxonomy(folders: folders)
    }
}
