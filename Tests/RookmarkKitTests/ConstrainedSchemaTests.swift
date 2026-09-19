import Foundation
import FoundationModels
import Testing
@testable import RookmarkKit

@Suite("ConstrainedClassificationSchema")
struct ConstrainedSchemaTests {

    @Test("make succeeds for representative folder set")
    func makeRepresentative() throws {
        let folders = ["Programming", "News", "Cooking", "Unsorted"]
        let schema = try ConstrainedClassificationSchema.make(allowedFolders: folders)
        let _ = schema
    }

    @Test("make with single folder succeeds")
    func makeSingleFolder() throws {
        let schema = try ConstrainedClassificationSchema.make(allowedFolders: ["Tech"])
        let _ = schema
    }

    @Test("make with empty folders throws")
    func makeEmpty() {
        #expect(throws: ConstrainedClassificationSchema.SchemaError.self) {
            try ConstrainedClassificationSchema.make(allowedFolders: [])
        }
    }

    @Test("make handles folders with spaces")
    func makeFoldersWithSpaces() throws {
        let folders = ["Web Dev", "Data Science", "Machine Learning"]
        let schema = try ConstrainedClassificationSchema.make(allowedFolders: folders)
        let _ = schema
    }

    @Test("make handles many folders up to cap")
    func makeManyFolders() throws {
        let folders = (1...40).map { "Folder\($0)" }
        let schema = try ConstrainedClassificationSchema.make(allowedFolders: folders)
        let _ = schema
    }
}

@Suite("FolderNameSanitizer")
struct FolderNameSanitizerTests {

    @Test("sanitize trims whitespace")
    func trimWhitespace() {
        #expect(FolderNameSanitizer.sanitize("  hello  ") == "Hello")
    }

    @Test("sanitize title-cases words")
    func titleCase() {
        #expect(FolderNameSanitizer.sanitize("web development") == "Web Development")
    }

    @Test("sanitize strips non-alphanumeric")
    func stripSpecialChars() {
        #expect(FolderNameSanitizer.sanitize("tech!@# stuff") == "Tech Stuff")
    }

    @Test("sanitize collapses multiple spaces")
    func collapseSpaces() {
        #expect(FolderNameSanitizer.sanitize("a    b    c") == "A B C")
    }

    @Test("sanitize returns empty for empty input")
    func emptyInput() {
        #expect(FolderNameSanitizer.sanitize("") == "")
    }

    @Test("sanitize returns empty for only special chars")
    func onlySpecialChars() {
        #expect(FolderNameSanitizer.sanitize("!@#$%") == "")
    }

    @Test("deduplicate removes case-insensitive duplicates")
    func deduplicate() {
        let folders = [
            Taxonomy.Folder(name: "Tech", rationale: ""),
            Taxonomy.Folder(name: "TECH", rationale: ""),
            Taxonomy.Folder(name: "News", rationale: ""),
        ]
        let result = FolderNameSanitizer.deduplicate(folders)
        #expect(result.count == 2)
        #expect(result[0].name == "Tech")
        #expect(result[1].name == "News")
    }

    @Test("deduplicate preserves order")
    func deduplicateOrder() {
        let folders = [
            Taxonomy.Folder(name: "Alpha", rationale: ""),
            Taxonomy.Folder(name: "Beta", rationale: ""),
            Taxonomy.Folder(name: "Gamma", rationale: ""),
        ]
        let result = FolderNameSanitizer.deduplicate(folders)
        #expect(result.map(\.name) == ["Alpha", "Beta", "Gamma"])
    }
}

@Suite("Classifier config")
struct ClassifierConfigTests {

    @Test("default confidence floor is 15")
    func defaultConfidenceFloor() {
        let config = Classifier.Config()
        #expect(config.confidenceFloor == 15)
    }

    @Test("confidence floor can be set to 0 to disable")
    func zeroFloor() {
        let config = Classifier.Config(confidenceFloor: 0)
        #expect(config.confidenceFloor == 0)
    }

    @Test("batch size defaults to auto so it tracks the live context window")
    func defaultBatchSize() {
        #expect(Classifier.Config().initialBatchSize == 0)
        #expect(Classifier.Config(initialBatchSize: 8).initialBatchSize == 8)
    }
}

@Suite("Derived batch size")
struct DerivedBatchSizeTests {

    private func makeClassifier(contextSize: Int, pinned: Int = 0) -> Classifier {
        Classifier(
            factory: SessionFactory(),
            config: .init(initialBatchSize: pinned),
            budget: TokenBudget(total: contextSize)
        )
    }

    private var bookmarks: [Bookmark] {
        (0..<40).map {
            Bookmark(id: "id\($0)", title: "Some bookmark title \($0)", url: "https://example.com/page/\($0)")
        }
    }

    @Test("a larger context window admits a larger batch")
    func scalesWithWindow() async {
        let block = "Development: code things\nDesign: visual things\n"
        let small = await makeClassifier(contextSize: 4096)
            .derivedInitialBatchSize(bookmarks, folderBlock: block)
        let large = await makeClassifier(contextSize: 8192)
            .derivedInitialBatchSize(bookmarks, folderBlock: block)

        #expect(small >= 1)
        #expect(large >= small, "a bigger window must never yield a smaller batch")
        #expect(large <= Classifier.autoBatchCap)
    }

    @Test("a taxonomy that eats the window shrinks the batch")
    func shrinksForLargeTaxonomy() async {
        let small = String(repeating: "Folder: a long rationale describing it\n", count: 20)
        let huge = String(repeating: "Folder: a long rationale describing it\n", count: 500)

        let roomy = await makeClassifier(contextSize: 4096)
            .derivedInitialBatchSize(bookmarks, folderBlock: small)
        let cramped = await makeClassifier(contextSize: 4096)
            .derivedInitialBatchSize(bookmarks, folderBlock: huge)

        #expect(cramped < roomy, "a bigger taxonomy must leave room for fewer items")
        #expect(cramped == 1, "nothing fits, so fall back to one at a time")
    }

    @Test("an explicit batch size overrides derivation")
    func pinnedWins() async {
        let size = await makeClassifier(contextSize: 8192, pinned: 3)
            .derivedInitialBatchSize(bookmarks, folderBlock: "Development: code\n")
        #expect(size == 3)
    }

    /// The old catch-all swallowed CancellationError, filed the rest of the run
    /// under Unsorted and reported success. Cancelling must surface instead.
    @Test("cancellation propagates rather than becoming Unsorted decisions")
    func cancellationPropagates() async {
        let classifier = makeClassifier(contextSize: 8192)
        let taxonomy = Taxonomy(folders: [.init(name: "Development", rationale: "code")])
        let items = bookmarks

        let task = Task { try await classifier.classify(items, taxonomy: taxonomy) }
        task.cancel()

        do {
            let decisions = try await task.value
            Issue.record("expected CancellationError, got \(decisions.count) decisions")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }
}

@Suite("TaxonomyBuilder pruneToCap")
struct PruneToCapTests {

    @Test("pruneToCap returns taxonomy unchanged when at or below cap")
    func belowCap() {
        let folders = [
            Taxonomy.Folder(name: "Tech", rationale: "Technology"),
            Taxonomy.Folder(name: "News", rationale: "Journalism"),
        ]
        let taxonomy = Taxonomy(folders: folders)
        let pruned = TaxonomyBuilder.pruneToCap(taxonomy, cap: 10)
        #expect(pruned.folders.count == 2)
    }

    @Test("pruneToCap reduces oversized taxonomy to cap")
    func reducesToCap() {
        let folders = (1...20).map { Taxonomy.Folder(name: "Folder\($0)", rationale: "Topic \($0)") }
        let taxonomy = Taxonomy(folders: folders)
        let pruned = TaxonomyBuilder.pruneToCap(taxonomy, cap: 10)
        #expect(pruned.folders.count == 10)
    }

    @Test("pruneToCap with cap=0 returns empty taxonomy")
    func capZero() {
        let folders = [Taxonomy.Folder(name: "Tech", rationale: "")]
        let taxonomy = Taxonomy(folders: folders)
        let pruned = TaxonomyBuilder.pruneToCap(taxonomy, cap: 0)
        #expect(pruned.folders.isEmpty)
    }

    @Test("pruneToCap merges semantically similar folders")
    func mergesSimilar() {
        let folders = [
            Taxonomy.Folder(name: "Programming", rationale: "Software development and coding"),
            Taxonomy.Folder(name: "Coding", rationale: "Writing software and programs"),
            Taxonomy.Folder(name: "Cooking", rationale: "Recipes and food preparation"),
            Taxonomy.Folder(name: "Baking", rationale: "Making bread and pastries"),
        ]
        let taxonomy = Taxonomy(folders: folders)
        let pruned = TaxonomyBuilder.pruneToCap(taxonomy, cap: 2, mergeThreshold: 0.70)
        #expect(pruned.folders.count == 2)
    }
}
