import Testing
@testable import LazyBookmarksKit

@Suite("URLNormalizer")
struct URLNormalizerTests {

    @Test("strips utm tracking parameters")
    func stripTracking() {
        let result = URLNormalizer.normalize("https://example.com/page?utm_source=twitter&id=42")
        #expect(result.contains("id=42"))
        #expect(!result.contains("utm_source"))
    }

    @Test("strips all known tracking params")
    func stripAllTracking() {
        let params = ["fbclid", "gclid", "msclkid", "igshid", "ref", "ref_src"]
        for param in params {
            let result = URLNormalizer.normalize("https://example.com/?\(param)=abc")
            #expect(!result.contains(param), "Should strip \(param)")
        }
    }

    @Test("removes www prefix from host")
    func stripWWW() {
        let result = URLNormalizer.normalize("https://www.example.com/path")
        #expect(result.contains("example.com"))
        #expect(!result.contains("www."))
    }

    @Test("lowercases scheme and host")
    func lowercase() {
        let result = URLNormalizer.normalize("HTTPS://EXAMPLE.COM/Path")
        #expect(result.hasPrefix("https://example.com"))
    }

    @Test("drops default ports")
    func defaultPorts() {
        let https = URLNormalizer.normalize("https://example.com:443/page")
        #expect(!https.contains(":443"))
        let http = URLNormalizer.normalize("http://example.com:80/page")
        #expect(!http.contains(":80"))
    }

    @Test("preserves non-default ports")
    func customPort() {
        let result = URLNormalizer.normalize("https://example.com:8080/page")
        #expect(result.contains(":8080"))
    }

    @Test("removes fragment")
    func fragment() {
        let result = URLNormalizer.normalize("https://example.com/page#section")
        #expect(!result.contains("#"))
    }

    @Test("removes trailing slash on non-root paths")
    func trailingSlash() {
        let result = URLNormalizer.normalize("https://example.com/path/")
        #expect(!result.hasSuffix("/"))
    }

    @Test("preserves trailing slash on root path")
    func rootSlash() {
        let result = URLNormalizer.normalize("https://example.com/")
        #expect(result.hasSuffix("/"))
    }

    @Test("sorts remaining query params for stability")
    func sortParams() {
        let result = URLNormalizer.normalize("https://example.com/?z=1&a=2&m=3")
        #expect(result.contains("a=2"))
        let aPos = result.range(of: "a=2")!.lowerBound
        let mPos = result.range(of: "m=3")!.lowerBound
        let zPos = result.range(of: "z=1")!.lowerBound
        #expect(aPos < mPos && mPos < zPos)
    }
}
