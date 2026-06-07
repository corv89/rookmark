import Foundation
import FoundationModels
import NaturalLanguage

public struct ClusteringConfig: Sendable {
    public var enabled: Bool
    public var similarityThreshold: Double
    public var mergeThreshold: Double
    public var minClusterSize: Int
    public var minResidue: Int
    public var maxNewFolders: Int
    public var namingSampleSize: Int
    public var enableLLMMerge: Bool
    public var folderLanguage: String?

    public init(
        enabled: Bool = false,
        similarityThreshold: Double = 0.62,
        mergeThreshold: Double = 0.80,
        minClusterSize: Int = 3,
        minResidue: Int = 8,
        maxNewFolders: Int = 12,
        namingSampleSize: Int = 8,
        enableLLMMerge: Bool = false,
        folderLanguage: String? = nil
    ) {
        self.enabled = enabled
        self.similarityThreshold = similarityThreshold
        self.mergeThreshold = mergeThreshold
        self.minClusterSize = minClusterSize
        self.minResidue = minResidue
        self.maxNewFolders = maxNewFolders
        self.namingSampleSize = namingSampleSize
        self.enableLLMMerge = enableLLMMerge
        self.folderLanguage = folderLanguage
    }
}

public struct Clusterer: Sendable {

    public struct Cluster: Sendable, Equatable {
        public var memberIDs: [String]
        public var centroid: [Float]
    }

    private let factory: SessionFactory
    private let budget: TokenBudget
    private let config: ClusteringConfig
    private let embedder: BookmarkEmbedder?

    public init(factory: SessionFactory, budget: TokenBudget, config: ClusteringConfig, embedder: BookmarkEmbedder? = nil) {
        self.factory = factory
        self.budget = budget
        self.config = config
        self.embedder = embedder
    }

    public func embed(_ bookmarks: [Bookmark]) -> [String: [Float]] {
        if let embedder {
            var result: [String: [Float]] = [:]
            result.reserveCapacity(bookmarks.count)
            for b in bookmarks {
                let text = ContextualEmbedder.normalizeForEmbedding(
                    "\(b.title.isEmpty ? "(untitled)" : b.title) \(b.domain)"
                )
                if let vec = try? embedder.vector(for: text) {
                    result[b.id] = vec
                }
            }
            return result
        }

        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return Self.fallbackEmbed(bookmarks)
        }
        var result: [String: [Float]] = [:]
        result.reserveCapacity(bookmarks.count)
        for b in bookmarks {
            let text = "\(b.title.isEmpty ? "(untitled)" : b.title) \(b.domain)"
            if let vec = embedding.vector(for: text) {
                result[b.id] = vec.map { Float($0) }
            }
        }
        return result
    }

    static func fallbackEmbed(_ bookmarks: [Bookmark]) -> [String: [Float]] {
        guard let wordEmb = NLEmbedding.wordEmbedding(for: .english) else { return [:] }
        let dim = wordEmb.dimension
        var result: [String: [Float]] = [:]
        for b in bookmarks {
            let words = "\(b.title) \(b.domain)".lowercased().split(separator: " ").map(String.init)
            var avg = Array(repeating: Float(0), count: dim)
            var count = 0
            for w in words {
                if let vec = wordEmb.vector(for: w) {
                    for (i, v) in vec.enumerated() { avg[i] += Float(v) }
                    count += 1
                }
            }
            if count > 0 {
                for i in avg.indices { avg[i] /= Float(count) }
            }
            result[b.id] = avg
        }
        return result
    }

    public func cluster(_ vectors: [String: [Float]]) -> [Cluster] {
        guard !vectors.isEmpty else { return [] }

        let sorted = vectors.sorted { $0.key < $1.key }
        var clusters: [Cluster] = []

        for (id, vec) in sorted {
            guard !vec.isEmpty else { continue }
            var bestIndex = -1
            var bestSim: Float = -1

            for (i, c) in clusters.enumerated() {
                let sim = Self.cosineSimilarity(vec, c.centroid)
                if sim > bestSim {
                    bestSim = sim
                    bestIndex = i
                }
            }

            if bestIndex >= 0 && Float(bestSim) >= Float(config.similarityThreshold) {
                clusters[bestIndex].memberIDs.append(id)
                let n = Float(clusters[bestIndex].memberIDs.count)
                for i in clusters[bestIndex].centroid.indices {
                    let old = clusters[bestIndex].centroid[i]
                    clusters[bestIndex].centroid[i] = old + (vec[i] - old) / n
                }
            } else {
                clusters.append(Cluster(memberIDs: [id], centroid: vec))
            }
        }

        return clusters.filter { $0.memberIDs.count >= config.minClusterSize }
    }

    public func name(
        _ clusters: [Cluster],
        bookmarks: [Bookmark],
        existing: [String]
    ) async throws -> [Taxonomy.Folder] {
        let bookmarkMap = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })
        let existingSet = Set(existing.map { $0.lowercased() })
        var proposed: [Taxonomy.Folder] = []

        let sorted = clusters.sorted { $0.memberIDs.count > $1.memberIDs.count }
        let capped = Array(sorted.prefix(config.maxNewFolders))

        let existingList = existing.joined(separator: ", ")
        let langInstruction: String
        if let lang = config.folderLanguage {
            langInstruction = " Name the folder in \(lang) regardless of the language of the bookmarks."
        } else {
            langInstruction = ""
        }
        let instructions = """
        You name bookmark folders. Generate a single folder with a short Title Case name \
        (1–3 words) and a one-sentence rationale. Do not repeat any existing folder name.\(langInstruction)
        """

        for cluster in capped {
            var sampleSize = config.namingSampleSize
            var generated: GeneratedFolder?

            while sampleSize >= 1 && generated == nil {
                let sample = nearestToCentroid(cluster, bookmarkMap: bookmarkMap)
                    .prefix(sampleSize)
                let items = sample.map { "\($0.title.isEmpty ? "(untitled)" : $0.title) | \($0.domain)" }
                    .joined(separator: "\n")

                let prompt = """
                These bookmarks belong together as a group. Propose a short Title Case folder name \
                (1–3 words) that describes their common topic. Do NOT duplicate any existing folder.

                Existing folders: \(existingList.isEmpty ? "(none)" : existingList)

                Bookmarks in this group:
                \(items)
                """

                guard budget.fits(instructions: instructions, prompt: prompt) else {
                    sampleSize = max(1, sampleSize / 2)
                    continue
                }

                let session = factory.makeSession(instructions: instructions)

                do {
                    generated = try await session.respond(
                        to: prompt, generating: GeneratedFolder.self
                    ).content
                } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                    sampleSize = max(1, sampleSize / 2)
                } catch {
                    break
                }
            }

            guard let generated else { continue }

            let name = FolderNameSanitizer.sanitize(generated.name)
            guard !name.isEmpty, !existingSet.contains(name.lowercased()) else { continue }
            guard !proposed.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            proposed.append(Taxonomy.Folder(name: name, rationale: generated.rationale))

            if proposed.count >= config.maxNewFolders { break }
        }

        return proposed
    }

    public func merge(
        _ proposed: [Taxonomy.Folder],
        existing: [Taxonomy.Folder]
    ) async -> [Taxonomy.Folder] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return proposed
        }

        var existingVectors: [(String, [Float])] = []
        for f in existing {
            if let vec = embedding.vector(for: f.name) {
                existingVectors.append((f.name, vec.map { Float($0) }))
            }
        }

        var accepted: [Taxonomy.Folder] = []
        var acceptedVectors: [(String, [Float])] = []

        for p in proposed {
            let pText = "\(p.name) \(p.rationale)"
            guard let pVec = embedding.vector(for: pText)?.map({ Float($0) }) else {
                accepted.append(p)
                continue
            }

            var tooSimilar = false
            for (name, eVec) in existingVectors {
                if Self.cosineSimilarity(pVec, eVec) >= Float(config.mergeThreshold) {
                    _ = name
                    tooSimilar = true
                    break
                }
            }
            if !tooSimilar {
                for (name, aVec) in acceptedVectors {
                    if Self.cosineSimilarity(pVec, aVec) >= Float(config.mergeThreshold) {
                        _ = name
                        tooSimilar = true
                        break
                    }
                }
            }

            if !tooSimilar {
                accepted.append(p)
                acceptedVectors.append((p.name, pVec))
            }
        }

        return accepted
    }

    private func nearestToCentroid(_ cluster: Cluster, bookmarkMap: [String: Bookmark]) -> [Bookmark] {
        cluster.memberIDs.compactMap { bookmarkMap[$0] }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    public static func vectorToBlob(_ v: [Float]) -> Data {
        var copy = v
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    public static func blobToVector(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { buffer in
            Array(UnsafeBufferPointer(start: buffer.baseAddress?.assumingMemoryBound(to: Float.self), count: count))
        }
    }
}
