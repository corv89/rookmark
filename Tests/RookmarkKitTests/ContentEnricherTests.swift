import Foundation
import Testing
@testable import RookmarkKit

@Suite("ContentEnricher (no-network)")
struct ContentEnricherTests {

    @Test("extractMetaDescription finds og:description (property first)")
    func ogDescriptionPropertyFirst() {
        let html = """
        <html><head>
        <meta property="og:description" content="A comprehensive guide to Swift concurrency.">
        </head></html>
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == "A comprehensive guide to Swift concurrency.")
    }

    @Test("extractMetaDescription finds og:description (content first)")
    func ogDescriptionContentFirst() {
        let html = """
        <meta content="Learn about async/await patterns" property="og:description">
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == "Learn about async/await patterns")
    }

    @Test("extractMetaDescription finds twitter:description")
    func twitterDescription() {
        let html = """
        <html><head>
        <meta name="twitter:description" content="The latest news in technology and science.">
        </head></html>
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == "The latest news in technology and science.")
    }

    @Test("extractMetaDescription finds plain description")
    func plainDescription() {
        let html = """
        <html><head>
        <meta name="description" content="A recipe for homemade pasta from scratch.">
        </head></html>
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == "A recipe for homemade pasta from scratch.")
    }

    @Test("extractMetaDescription prefers og:description over plain description")
    func ogOverPlain() {
        let html = """
        <html><head>
        <meta name="description" content="Generic site description.">
        <meta property="og:description" content="Specific article summary about Swift.">
        </head></html>
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == "Specific article summary about Swift.")
    }

    @Test("extractMetaDescription returns nil for no meta tags")
    func noMetaTags() {
        let html = "<html><head><title>Test</title></head></html>"
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == nil)
    }

    @Test("extractMetaDescription returns nil for short descriptions")
    func shortDescription() {
        let html = """
        <meta name="description" content="Short">
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == nil)
    }

    @Test("extractMetaDescription truncates to 300 chars")
    func truncation() {
        let longDesc = String(repeating: "a", count: 400)
        let html = """
        <meta name="description" content="\(longDesc)">
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result?.count == 300)
    }

    @Test("extractMetaDescription is case-insensitive")
    func caseInsensitive() {
        let html = """
        <META NAME="Description" CONTENT="A case-insensitive test description.">
        """
        let result = ContentEnricher.extractMetaDescription(html)
        #expect(result == "A case-insensitive test description.")
    }

    @Test("decodeHTMLEntities handles common entities")
    func decodeEntities() {
        let input = "Tom &amp; Jerry &lt;3 &quot;friends&quot;"
        let result = ContentEnricher.decodeHTMLEntities(input)
        #expect(result == "Tom & Jerry <3 \"friends\"")
    }

    @Test("EnrichResult stores bookmark data correctly")
    func enrichResult() {
        let result = ContentEnricher.EnrichResult(
            bookmarkID: "abc123",
            metaDescription: "A test description",
            isDeadLink: false
        )
        #expect(result.bookmarkID == "abc123")
        #expect(result.metaDescription == "A test description")
        #expect(result.isDeadLink == false)
    }

    @Test("EnrichResult handles dead link")
    func enrichResultDeadLink() {
        let result = ContentEnricher.EnrichResult(
            bookmarkID: "dead1",
            metaDescription: nil,
            isDeadLink: true
        )
        #expect(result.isDeadLink == true)
        #expect(result.metaDescription == nil)
    }

    @Test("Enrichment model round-trips through Codable")
    func enrichmentCodable() throws {
        let original = Enrichment(
            bookmarkID: "test1",
            metaDescription: "A test",
            isDeadLink: false,
            httpStatus: 200,
            fetchedAt: Date(timeIntervalSince1970: 1000000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Enrichment.self, from: data)
        #expect(decoded == original)
    }
}
