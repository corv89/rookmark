import Testing
@testable import LazyBookmarksKit

@Suite("NetscapeBookmarkParser")
struct ParserTests {

    @Test("flat bookmarks parse with titles and urls")
    func flat() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://swift.org/">Swift</A>
            <DT><A HREF="https://www.apple.com/?utm_source=x">Apple</A>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.count == 2)
        #expect(r.bookmarks[0].title == "Swift")
        #expect(r.bookmarks[0].originalFolderPath.isEmpty)
    }

    @Test("nested folders produce folder paths and existingFolders")
    func nested() {
        let html = """
        <DL><p>
            <DT><H3>Dev</H3>
            <DL><p>
                <DT><A HREF="https://swift.org">Swift</A>
                <DT><H3>Apple</H3>
                <DL><p>
                    <DT><A HREF="https://developer.apple.com">Dev Portal</A>
                </DL><p>
            </DL><p>
        </DL><p>
        """
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.existingFolders.contains("Dev"))
        #expect(r.existingFolders.contains("Apple"))
        let portal = r.bookmarks.first { $0.title == "Dev Portal" }
        #expect(portal?.originalFolderPath == ["Dev", "Apple"])
    }

    @Test("entities in titles are decoded")
    func entities() {
        let html = #"<DL><p><DT><A HREF="https://x.com">A &amp; B &#8212; C</A></DL><p>"#
        let r = NetscapeBookmarkParser().parse(html)
        #expect(r.bookmarks.first?.title == "A & B — C")
    }
}
