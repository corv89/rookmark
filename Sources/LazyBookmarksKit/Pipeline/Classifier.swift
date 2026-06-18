import Foundation
import FoundationModels

/// Phase 3 of the pipeline: assign each bookmark to a taxonomy folder using the
/// on-device model, one short batch at a time.
///
/// Design rules driven by the 4 096-token window and the shared model resource:
///  • A fresh `LanguageModelSession` per batch — never accumulate transcript.
///  • Short, token-budgeted batches; shrink-and-retry on context overflow.
///  • Refusals are an expected per-item outcome → isolate, then route to Unsorted.
///  • Sequential by default (concurrency buys little on a serialized resource).
public actor Classifier {

    public struct Config: Sendable {
        public var initialBatchSize: Int
        public var minBatchSize: Int
        public var confidenceFloor: Int
        public var maxConcurrency: Int

        public init(
            initialBatchSize: Int = 6,
            minBatchSize: Int = 1,
            confidenceFloor: Int = 15,
            maxConcurrency: Int = 1
        ) {
            self.initialBatchSize = initialBatchSize
            self.minBatchSize = minBatchSize
            self.confidenceFloor = confidenceFloor
            self.maxConcurrency = maxConcurrency
        }
    }

    public struct Decision: Sendable, Equatable {
        public var bookmarkID: String
        public var folder: String
        public var confidence: Int
        public var modelChosenFolder: String?

        public init(bookmarkID: String, folder: String, confidence: Int, modelChosenFolder: String? = nil) {
            self.bookmarkID = bookmarkID
            self.folder = folder
            self.confidence = confidence
            self.modelChosenFolder = modelChosenFolder
        }
    }

    /// Reports per-batch progress (committed count, total). Hook the CLI bar here.
    public typealias ProgressHandler = @Sendable (_ done: Int, _ total: Int) -> Void

    /// Counts of why bookmarks ended up in Unsorted.
    public struct UnsortedCauses: Sendable, Equatable {
        public var modelChoseUnsorted: Int = 0
        public var belowFloor: Int = 0
        public var unmapped: Int = 0

        public var total: Int { modelChoseUnsorted + belowFloor + unmapped }
    }

    private let factory: SessionFactory
    private let config: Config
    private let budget: TokenBudget
    private let schema: GenerationSchema?
    public private(set) var refusalCount: Int = 0
    public private(set) var unsortedCauses: UnsortedCauses = UnsortedCauses()

    public init(factory: SessionFactory, config: Config, budget: TokenBudget, taxonomy: Taxonomy? = nil) {
        self.factory = factory
        self.config = config
        self.budget = budget
        if let t = taxonomy {
            self.schema = try? ConstrainedClassificationSchema.make(allowedFolders: t.allowedFolderNames)
        } else {
            self.schema = nil
        }
    }

    private static let instructions = """
    You sort web bookmarks into folders. You are given a list of allowed folders \
    (name: description) and a list of items, each as `id | title | url`. \
    For every item, choose the single best-fitting folder from the allowed list. \
    Focus on what the page is actually about based on its title and URL path, \
    not just the domain name. For example, a Wikipedia article about electric \
    vehicles belongs in the EV folder, not Search & Reference. \
    If none fits well, choose "Unsorted". Return exactly one assignment per item \
    and echo each id exactly. Do not invent folders.
    """

    /// Classifies all bookmarks against `taxonomy`. Pure: returns decisions; the
    /// caller persists/commits (enables resume + undo).
    public func classify(
        _ bookmarks: [Bookmark],
        taxonomy: Taxonomy,
        progress: ProgressHandler? = nil
    ) async -> [Decision] {
        let allowed = Set(taxonomy.allowedFolderNames.map(Self.canonical))
        let folderBlock = Self.renderFolders(taxonomy)

        var decisions: [Decision] = []
        decisions.reserveCapacity(bookmarks.count)
        var index = 0
        var batchSize = config.initialBatchSize

        while index < bookmarks.count {
            let end = min(index + batchSize, bookmarks.count)
            let slice = Array(bookmarks[index..<end])

            do {
                let batch = try await classifyBatch(slice, folderBlock: folderBlock,
                                                     allowed: allowed, taxonomy: taxonomy)
                decisions.append(contentsOf: batch)
                index = end
                progress?(decisions.count, bookmarks.count)
                // Recover toward the configured size after a successful batch.
                batchSize = min(config.initialBatchSize, batchSize + 1)
            } catch let err as ClassifierError {
                switch err {
                case .contextOverflow where batchSize > config.minBatchSize:
                    batchSize = max(config.minBatchSize, batchSize / 2)   // shrink + retry
                case .refused where slice.count > 1:
                    batchSize = config.minBatchSize                        // isolate the culprit
                default:
                    // Single item still failing → park it in Unsorted, move on.
                    decisions.append(contentsOf: slice.map {
                        Decision(bookmarkID: $0.id, folder: Taxonomy.unsorted, confidence: 0)
                    })
                    unsortedCauses.unmapped += slice.count
                    index = end
                    progress?(decisions.count, bookmarks.count)
                }
            } catch {
                decisions.append(contentsOf: slice.map {
                    Decision(bookmarkID: $0.id, folder: Taxonomy.unsorted, confidence: 0)
                })
                unsortedCauses.unmapped += slice.count
                index = end
                progress?(decisions.count, bookmarks.count)
            }
        }
        return decisions
    }

    // MARK: - One batch

    private func classifyBatch(
        _ slice: [Bookmark],
        folderBlock: String,
        allowed: Set<String>,
        taxonomy: Taxonomy
    ) async throws -> [Decision] {
        // Local ids (b0, b1, …) keep the prompt tiny and avoid the model echoing
        // long URLs back at us.
        let prompt = Self.renderPrompt(slice, folderBlock: folderBlock)
        guard budget.fits(instructions: Self.instructions, prompt: prompt) else {
            throw ClassifierError.contextOverflow
        }

        let session = factory.makeSession(instructions: Self.instructions)

        var byLocalID: [String: Bookmark] = [:]
        for (i, b) in slice.enumerated() { byLocalID["b\(i)"] = b }

        var assignments: [(id: String, folder: String, confidence: Int)] = []

        if let schema {
            let content: GeneratedContent
            do {
                content = try await session.respond(to: prompt, schema: schema, options: factory.generationOptions).content
            } catch let e as LanguageModelSession.GenerationError {
                switch e {
                case .exceededContextWindowSize:
                    throw ClassifierError.contextOverflow
                case .refusal:
                    refusalCount += 1
                    throw ClassifierError.refused
                default:
                    throw ClassifierError.generation(String(describing: e))
                }
            }
            let rawAssignments = try content.value([GeneratedContent].self, forProperty: "assignments")
            for item in rawAssignments {
                let id = try item.value(String.self, forProperty: "id")
                let folder = try item.value(String.self, forProperty: "folder")
                let confidence = try item.value(Int.self, forProperty: "confidence")
                assignments.append((id: id, folder: folder, confidence: confidence))
            }
        } else {
            // Schema unavailable (should not happen when taxonomy is within cap).
            // Fall back to Unsorted for all items in this batch.
            for b in slice {
                assignments.append((id: b.id, folder: Taxonomy.unsorted, confidence: 0))
                unsortedCauses.unmapped += 1
            }
        }

        var out: [Decision] = []
        for a in assignments {
            guard let b = byLocalID[a.id.lowercased()] else { continue }
            let folder = Self.validate(a.folder, allowed: allowed, taxonomy: taxonomy)
            let conf = max(0, min(100, a.confidence))

            if folder == Taxonomy.unsorted {
                unsortedCauses.modelChoseUnsorted += 1
                out.append(Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: conf))
            } else if conf < config.confidenceFloor {
                unsortedCauses.belowFloor += 1
                out.append(Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: conf, modelChosenFolder: folder))
            } else {
                out.append(Decision(bookmarkID: b.id, folder: folder, confidence: conf))
            }
        }
        let returned = Set(out.map(\.bookmarkID))
        for b in slice where !returned.contains(b.id) {
            unsortedCauses.unmapped += 1
            out.append(Decision(bookmarkID: b.id, folder: Taxonomy.unsorted, confidence: 0))
        }
        return out
    }

    // MARK: - Rendering & validation

    static func renderFolders(_ t: Taxonomy) -> String {
        let lines = t.folders.map { "- \($0.name)" + ($0.rationale.isEmpty ? "" : ": \($0.rationale)") }
        return (lines + ["- \(Taxonomy.unsorted): anything that fits nowhere above"]).joined(separator: "\n")
    }

    static func renderPrompt(_ slice: [Bookmark], folderBlock: String) -> String {
        let items = slice.enumerated().map { i, b in
            "b\(i) | \(b.title.isEmpty ? "(untitled)" : b.title) | \(b.url)"
        }.joined(separator: "\n")
        return """
        Allowed folders:
        \(folderBlock)

        Items:
        \(items)
        """
    }

    static func canonical(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exact match → case/space-insensitive match → Unsorted.
    static func validate(_ raw: String, allowed: Set<String>, taxonomy: Taxonomy) -> String {
        let c = canonical(raw)
        guard allowed.contains(c) else { return Taxonomy.unsorted }
        // Return the canonically-cased taxonomy name, not the model's casing.
        if c == canonical(Taxonomy.unsorted) { return Taxonomy.unsorted }
        return taxonomy.names.first { canonical($0) == c } ?? Taxonomy.unsorted
    }
}

public enum ClassifierError: Error, Sendable {
    case contextOverflow
    case refused
    case generation(String)
}
