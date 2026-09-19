import Foundation

public actor ContentEnricher {

    public struct Config: Sendable {
        public var concurrency: Int
        public var timeout: TimeInterval
        public var maxRetries: Int
        public var maxDescriptionLength: Int

        public init(
            concurrency: Int = 5,
            timeout: TimeInterval = 15,
            maxRetries: Int = 1,
            maxDescriptionLength: Int = 300
        ) {
            self.concurrency = concurrency
            self.timeout = timeout
            self.maxRetries = maxRetries
            self.maxDescriptionLength = maxDescriptionLength
        }
    }

    public typealias ProgressHandler = @Sendable (_ done: Int, _ total: Int) -> Void
    public typealias DeadLinkHandler = @Sendable (_ title: String, _ url: String, _ reason: String) -> Void

    private let config: Config
    private let store: Store?
    private var deadLinks: [(title: String, url: String, reason: String)] = []

    public init(config: Config = Config(), store: Store? = nil) {
        self.config = config
        self.store = store
    }

    public struct EnrichResult: Sendable {
        public var bookmarkID: String
        public var metaDescription: String?
        public var isDeadLink: Bool
    }

    public func enrich(
        _ bookmarks: [Bookmark],
        refresh: Bool = false,
        progress: ProgressHandler? = nil,
        onDeadLink: DeadLinkHandler? = nil
    ) async -> [String: EnrichResult] {
        var results: [String: EnrichResult] = [:]

        let cached: [String: Enrichment]
        if !refresh, let store {
            let ids = Set(bookmarks.map(\.id))
            cached = (try? store.getEnrichments(bookmarkIDs: ids)) ?? [:]
        } else {
            cached = [:]
        }

        for (id, e) in cached {
            results[id] = EnrichResult(
                bookmarkID: id,
                metaDescription: e.metaDescription,
                isDeadLink: e.isDeadLink
            )
        }
        progress?(results.count, bookmarks.count)

        let toFetch = bookmarks.filter { !cached.keys.contains($0.id) }
        guard !toFetch.isEmpty else { return results }

        var fetched = results.count

        await withTaskGroup(of: EnrichResult.self) { group in
            var iterator = toFetch.makeIterator()
            var inflight = 0

            func addNext() {
                guard let bm = iterator.next() else { return }
                inflight += 1
                group.addTask {
                    await self.fetchOne(bm)
                }
            }

            for _ in 0..<min(config.concurrency, toFetch.count) { addNext() }

            for await result in group {
                results[result.bookmarkID] = result
                if result.isDeadLink {
                    let bm = toFetch.first { $0.id == result.bookmarkID }
                    let title = bm?.title ?? "(untitled)"
                    let url = bm?.url ?? ""
                    deadLinks.append((title: title, url: url, reason: "HTTP error"))
                    onDeadLink?(title, url, "HTTP error")
                }
                fetched += 1
                progress?(fetched, bookmarks.count)
                try? store?.setEnrichment(Enrichment(
                    bookmarkID: result.bookmarkID,
                    metaDescription: result.metaDescription,
                    isDeadLink: result.isDeadLink,
                    httpStatus: nil,
                    fetchedAt: .now
                ))
                inflight -= 1
                addNext()
            }
        }

        return results
    }

    public func getDeadLinks() -> [(title: String, url: String, reason: String)] {
        deadLinks
    }

    private nonisolated func fetchOne(_ bookmark: Bookmark) async -> EnrichResult {
        guard let url = URL(string: bookmark.url) else {
            return EnrichResult(bookmarkID: bookmark.id, metaDescription: nil, isDeadLink: true)
        }

        for attempt in 0...0 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("rookmark/1.0 (+https://github.com/rookmark)", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")

            let sessionConfig = URLSessionConfiguration.default
            sessionConfig.httpMaximumConnectionsPerHost = 1
            sessionConfig.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: sessionConfig)

            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let code = http.statusCode
                    if code == 404 || code == 410 || code >= 500 {
                        return EnrichResult(bookmarkID: bookmark.id, metaDescription: nil, isDeadLink: true)
                    }
                    if code >= 200 && code < 300 {
                        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                        let description = Self.extractMetaDescription(html)
                        return EnrichResult(bookmarkID: bookmark.id, metaDescription: description, isDeadLink: false)
                    }
                    if code >= 300 && code < 400 {
                        return EnrichResult(bookmarkID: bookmark.id, metaDescription: nil, isDeadLink: false)
                    }
                    if attempt == 0 { continue }
                }
            } catch is URLError {
                return EnrichResult(bookmarkID: bookmark.id, metaDescription: nil, isDeadLink: true)
            } catch {
                if attempt == 0 { continue }
            }
        }

        return EnrichResult(bookmarkID: bookmark.id, metaDescription: nil, isDeadLink: true)
    }

    public nonisolated static func extractMetaDescription(_ html: String) -> String? {
        let patterns: [(String, Int)] = [
            (#"<meta\s+[^>]*property\s*=\s*["']og:description["'][^>]*content\s*=\s*["']([^"']+)["'][^>]*/?>"#, 1),
            (#"<meta\s+[^>]*content\s*=\s*["']([^"']+)["'][^>]*property\s*=\s*["']og:description["'][^>]*/?>"#, 1),
            (#"<meta\s+[^>]*name\s*=\s*["']twitter:description["'][^>]*content\s*=\s*["']([^"']+)["'][^>]*/?>"#, 1),
            (#"<meta\s+[^>]*content\s*=\s*["']([^"']+)["'][^>]*name\s*=\s*["']twitter:description["'][^>]*/?>"#, 1),
            (#"<meta\s+[^>]*name\s*=\s*["']description["'][^>]*content\s*=\s*["']([^"']+)["'][^>]*/?>"#, 1),
            (#"<meta\s+[^>]*content\s*=\s*["']([^"']+)["'][^>]*name\s*=\s*["']description["'][^>]*/?>"#, 1),
        ]

        for (pattern, group) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, range: range) {
                if let nsRange = Range(match.range(at: group), in: html) {
                    let desc = String(html[nsRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if desc.count >= 10 {
                        return String(desc.prefix(300))
                    }
                }
            }
        }
        return nil
    }

    public nonisolated static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
