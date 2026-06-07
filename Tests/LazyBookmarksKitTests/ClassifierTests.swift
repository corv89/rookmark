import Testing
@testable import LazyBookmarksKit

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

    @Test("renderPrompt uses local ids and domains")
    func renderPrompt() {
        let bookmarks = [
            Bookmark(id: "abc", title: "Swift Lang", url: "https://swift.org/docs"),
            Bookmark(id: "def", title: "BBC News", url: "https://bbc.co.uk/news"),
        ]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock)
        #expect(prompt.contains("b0 | Swift Lang | swift.org"))
        #expect(prompt.contains("b1 | BBC News | bbc.co.uk"))
        #expect(!prompt.contains("https://swift.org/docs"))
    }

    @Test("renderPrompt shows (untitled) for empty titles")
    func untitled() {
        let bookmarks = [Bookmark(id: "x", title: "", url: "https://example.com")]
        let folderBlock = Classifier.renderFolders(Self.taxonomy)
        let prompt = Classifier.renderPrompt(bookmarks, folderBlock: folderBlock)
        #expect(prompt.contains("(untitled)"))
    }
}
