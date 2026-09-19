import Testing
@testable import RookmarkKit

@Suite("Classifier (no-model)")
struct ClassifierTests {

    static let taxonomy = Taxonomy(folders: [
        .init(name: "Programming", rationale: "Code and software development"),
        .init(name: "News", rationale: "Current events and journalism"),
        .init(name: "Cooking", rationale: "Recipes and food"),
    ])

    static let allowed = Set(taxonomy.allowedFolderNames.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })

    @Test("validate returns exact match")
    func exactMatch() {
        let result = Classifier.validate("Programming", allowed: Self.allowed, taxonomy: Self.taxonomy)
        #expect(result == "Programming")
    }

    @Test("validate is case-insensitive")
    func caseInsensitive() {
        let result = Classifier.validate("programming", allowed: Self.allowed, taxonomy: Self.taxonomy)
        #expect(result == "Programming")
    }

    @Test("validate is whitespace-insensitive")
    func whitespaceInsensitive() {
        let result = Classifier.validate("  Programming  ", allowed: Self.allowed, taxonomy: Self.taxonomy)
        #expect(result == "Programming")
    }

    @Test("validate routes unknown folders to Unsorted")
    func unknownFolder() {
        let result = Classifier.validate("Nonexistent", allowed: Self.allowed, taxonomy: Self.taxonomy)
        #expect(result == Taxonomy.unsorted)
    }

    @Test("validate accepts Unsorted")
    func unsorted() {
        let result = Classifier.validate("Unsorted", allowed: Self.allowed, taxonomy: Self.taxonomy)
        #expect(result == Taxonomy.unsorted)
    }

    @Test("renderFolders includes all folders plus Unsorted sentinel")
    func renderFolders() {
        let rendered = Classifier.renderFolders(Self.taxonomy)
        #expect(rendered.contains("Programming"))
        #expect(rendered.contains("News"))
        #expect(rendered.contains("Cooking"))
        #expect(rendered.contains("Unsorted"))
    }

    @Test("renderFolders omits colon when rationale is empty")
    func renderFoldersEmptyRationale() {
        let t = Taxonomy(folders: [
            .init(name: "News", rationale: "Current events"),
            .init(name: "Tech", rationale: ""),
        ])
        let rendered = Classifier.renderFolders(t)
        #expect(rendered.contains("- News: Current events"))
        #expect(rendered.contains("- Tech"))
        #expect(!rendered.contains("- Tech:"))
    }

    @Test("renderPrompt uses local ids and full URLs")
    func renderPrompt() {
        let bookmarks = [
            Bookmark(id: "abc", title: "Swift Lang", url: "https://swift.org/docs"),
            Bookmark(id: "def", title: "BBC News", url: "https://bbc.co.uk/news"),
        ]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock)
        #expect(prompt.contains("b0 | Swift Lang | https://swift.org/docs"))
        #expect(prompt.contains("b1 | BBC News | https://bbc.co.uk/news"))
    }

    @Test("renderPrompt shows (untitled) for empty titles")
    func untitled() {
        let bookmarks = [Bookmark(id: "x", title: "", url: "https://example.com")]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock)
        #expect(prompt.contains("(untitled)"))
    }

    @Test("Decision.modelChosenFolder is nil by default")
    func decisionModelChosenFolderDefault() {
        let d = Classifier.Decision(bookmarkID: "a", folder: "News", confidence: 80)
        #expect(d.modelChosenFolder == nil)
    }

    @Test("Decision.modelChosenFolder preserves pre-demotion folder")
    func decisionModelChosenFolderBelowFloor() {
        let d = Classifier.Decision(bookmarkID: "a", folder: Taxonomy.unsorted, confidence: 8, modelChosenFolder: "Cooking")
        #expect(d.folder == Taxonomy.unsorted)
        #expect(d.modelChosenFolder == "Cooking")
        #expect(d.confidence == 8)
    }

    @Test("renderPrompt includes meta descriptions when enrichments provided")
    func renderPromptWithEnrichments() {
        let bookmarks = [
            Bookmark(id: "abc", title: "Swift Lang", url: "https://swift.org/docs"),
            Bookmark(id: "def", title: "BBC News", url: "https://bbc.co.uk/news"),
        ]
        let enrichments: [String: ContentEnricher.EnrichResult] = [
            "abc": .init(bookmarkID: "abc", metaDescription: "Official Swift documentation", isDeadLink: false),
            "def": .init(bookmarkID: "def", metaDescription: "British Broadcasting Corporation news", isDeadLink: false),
        ]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock, enrichments: enrichments)
        #expect(prompt.contains("b0 | Swift Lang | https://swift.org/docs | Official Swift documentation"))
        #expect(prompt.contains("b1 | BBC News | https://bbc.co.uk/news | British Broadcasting Corporation news"))
    }

    @Test("renderPrompt omits description when enrichment is nil")
    func renderPromptWithoutEnrichments() {
        let bookmarks = [
            Bookmark(id: "abc", title: "Swift Lang", url: "https://swift.org/docs"),
        ]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock, enrichments: nil)
        #expect(prompt.contains("b0 | Swift Lang | https://swift.org/docs"))
        #expect(!prompt.contains(" | Official"))
    }

    @Test("renderPrompt skips description when meta is nil for that bookmark")
    func renderPromptPartialEnrichments() {
        let bookmarks = [
            Bookmark(id: "abc", title: "Swift Lang", url: "https://swift.org/docs"),
            Bookmark(id: "def", title: "BBC News", url: "https://bbc.co.uk/news"),
        ]
        let enrichments: [String: ContentEnricher.EnrichResult] = [
            "abc": .init(bookmarkID: "abc", metaDescription: "Swift docs", isDeadLink: false),
        ]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock, enrichments: enrichments)
        #expect(prompt.contains("b0 | Swift Lang | https://swift.org/docs | Swift docs"))
        #expect(prompt.contains("b1 | BBC News | https://bbc.co.uk/news\n") || prompt.hasSuffix("b1 | BBC News | https://bbc.co.uk/news"))
    }
}
