import Testing
@testable import LazyBookmarksKit

@Suite("NetscapeBookmarkWriter")
struct WriterTests {

    @Test("produces valid Netscape bookmark HTML")
    func basicOutput() {
        let bookmarks = [
            Bookmark(id: "a", title: "Swift", url: "https://swift.org", assignedFolder: "Dev"),
            Bookmark(id: "b", title: "Apple", url: "https://apple.com", assignedFolder: "Dev"),
        ]
        let html = NetscapeBookmarkWriter().write(bookmarks)
        #expect(html.contains("NETSCAPE-Bookmark-file-1"))
        #expect(html.contains("<H3>Dev</H3>"))
        #expect(html.contains("HREF=\"https://swift.org\""))
    }

    @Test("unsorted bookmarks appear last")
    func unsortedLast() {
        let bookmarks = [
            Bookmark(id: "a", title: "X", url: "https://x.com", assignedFolder: "Unsorted"),
            Bookmark(id: "b", title: "Y", url: "https://y.com", assignedFolder: "Alpha"),
        ]
        let html = NetscapeBookmarkWriter().write(bookmarks)
        let alphaPos = html.range(of: "Alpha")!.lowerBound
        let unsortedPos = html.range(of: "Unsorted")!.lowerBound
        #expect(alphaPos < unsortedPos)
    }

    @Test("nil assignedFolder defaults to Unsorted")
    func nilFolder() {
        let bookmarks = [Bookmark(id: "a", title: "X", url: "https://x.com")]
        let html = NetscapeBookmarkWriter().write(bookmarks)
        #expect(html.contains("Unsorted"))
    }

    @Test("escapes special characters in titles and URLs")
    func escaping() {
        let bookmarks = [
            Bookmark(id: "a", title: "A & B <C>", url: "https://example.com/?q=1&r=2",
                     assignedFolder: "Test"),
        ]
        let html = NetscapeBookmarkWriter().write(bookmarks)
        #expect(html.contains("A &amp; B &lt;C&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test("round-trip: parse then write preserves bookmarks")
    func roundTrip() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><H3>Tech</H3>
            <DL><p>
                <DT><A HREF="https://swift.org">Swift</A>
                <DT><A HREF="https://apple.com">Apple</A>
            </DL><p>
        </DL><p>
        """
        var parsed = NetscapeBookmarkParser().parse(html)
        #expect(parsed.bookmarks.count == 2)

        for i in parsed.bookmarks.indices {
            parsed.bookmarks[i].assignedFolder = "Tech"
        }

        let written = NetscapeBookmarkWriter().write(parsed.bookmarks)
        #expect(written.contains("Swift"))
        #expect(written.contains("Apple"))
        #expect(written.contains("Tech"))

        let reparsed = NetscapeBookmarkParser().parse(written)
        #expect(reparsed.bookmarks.count == 2)
    }
}
