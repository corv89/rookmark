import Testing
@testable import RookmarkKit

@Suite("Parser — malformed input")
struct MalformedParserTests {

    @Test("unclosed DL tags are handled gracefully")
    func unclosedDL() {
        let html = """
        <DL><p>
            <DT><H3>Dev</H3>
            <DL><p>
                <DT><A HREF="https://swift.org">Swift</A>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.count == 1)
        #expect(r.bookmarks[0].title == "Swift")
    }

    @Test("missing closing H3 tag does not crash")
    func unclosedH3() {
        let html = """
        <DL><p>
            <DT><H3>Dev
            <DL><p>
                <DT><A HREF="https://swift.org">Swift</A>
            </DL><p>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.count >= 0)
    }

    @Test("empty href is skipped")
    func emptyHref() {
        let html = """
        <DL><p>
            <DT><A HREF="">Empty</A>
            <DT><A HREF="https://swift.org">Swift</A>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.count == 1)
        #expect(r.bookmarks[0].title == "Swift")
    }

    @Test("duplicate URLs are deduplicated")
    func duplicates() {
        let html = """
        <DL><p>
            <DT><A HREF="https://swift.org">Swift</A>
            <DT><A HREF="https://swift.org">Swift Again</A>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.count == 1)
    }

    @Test("ADD_DATE attribute is parsed")
    func addDate() {
        let html = """
        <DL><p>
            <DT><A HREF="https://swift.org" ADD_DATE="1609459200">Swift</A>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks[0].addedAt != nil)
    }

    @Test("completely empty input produces empty result")
    func empty() {
        let r = NetscapeBookmarkParser().parse("")
        #expect(r.bookmarks.isEmpty)
        #expect(r.existingFolders.isEmpty)
    }

    @Test("base64 favicon data in attributes does not interfere")
    func base64Icon() {
        let html = """
        <DL><p>
            <DT><A HREF="https://example.com" ICON="data:image/png;base64,iVBORw0KGgo=">Site</A>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.count == 1)
        #expect(r.bookmarks[0].url == "https://example.com")
    }

    @Test("deeply nested folders produce correct paths")
    func deepNesting() {
        let html = """
        <DL><p>
            <DT><H3>L1</H3>
            <DL><p>
                <DT><H3>L2</H3>
                <DL><p>
                    <DT><H3>L3</H3>
                    <DL><p>
                        <DT><A HREF="https://deep.com">Deep</A>
                    </DL><p>
                </DL><p>
            </DL><p>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        let deep = r.bookmarks.first { $0.title == "Deep" }
        #expect(deep?.originalFolderPath == ["L1", "L2", "L3"])
    }
}
