import Foundation

public struct LinkChecker: Sendable {

    public enum Status: String, Sendable { case alive, dead, redirected, unknown }
    public struct Report: Sendable { public var bookmarkID: String; public var status: Status }

    public var concurrency: Int
    public init(concurrency: Int = 8) { self.concurrency = concurrency }

    public func check(_ bookmarks: [Bookmark]) async -> [Report] {
        await withTaskGroup(of: Report.self) { group in
            var reports: [Report] = []
            var iterator = bookmarks.makeIterator()

            func addNext() {
                guard let bm = iterator.next() else { return }
                group.addTask { await Self.checkOne(bm) }
            }

            for _ in 0..<min(concurrency, bookmarks.count) { addNext() }

            for await report in group {
                reports.append(report)
                addNext()
            }
            return reports
        }
    }

    private static func checkOne(_ bookmark: Bookmark) async -> Report {
        guard let url = URL(string: bookmark.url) else {
            return Report(bookmarkID: bookmark.id, status: .dead)
        }

        for method in ["HEAD", "GET"] {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 15
            request.setValue("lazybm/1.0", forHTTPHeaderField: "User-Agent")

            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config)

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let code = http.statusCode
                    switch code {
                    case 200..<300:
                        return Report(bookmarkID: bookmark.id, status: .alive)
                    case 301, 302, 303, 307, 308:
                        return Report(bookmarkID: bookmark.id, status: .redirected)
                    case 403 where method == "HEAD", 405 where method == "HEAD", 501 where method == "HEAD":
                        continue
                    default:
                        return Report(bookmarkID: bookmark.id, status: .dead)
                    }
                }
            } catch {
                if method == "HEAD" { continue }
                return Report(bookmarkID: bookmark.id, status: .dead)
            }
        }
        return Report(bookmarkID: bookmark.id, status: .unknown)
    }
}
