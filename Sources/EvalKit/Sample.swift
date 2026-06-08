import Foundation
import LazyBookmarksKit

public enum Sampler {

    public struct SampleRow: Sendable, Equatable {
        public var bookmarkID: String
        public var title: String
        public var url: String
        public var domain: String
        public var assignedFolder: String
        public var confidence: Int
        public var verdict: String
        public var note: String

        public init(
            bookmarkID: String,
            title: String,
            url: String,
            domain: String,
            assignedFolder: String,
            confidence: Int,
            verdict: String = "",
            note: String = ""
        ) {
            self.bookmarkID = bookmarkID
            self.title = title
            self.url = url
            self.domain = domain
            self.assignedFolder = assignedFolder
            self.confidence = confidence
            self.verdict = verdict
            self.note = note
        }
    }

    public static func stratifiedSample(
        decisions: [Classifier.Decision],
        bookmarks: [Bookmark],
        n: Int,
        seed: UInt64
    ) -> [SampleRow] {
        guard n > 0, !decisions.isEmpty else { return [] }

        let bookmarkMap = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })

        var strata: [[Classifier.Decision]] = []
        let bins = [(0, 25), (25, 50), (50, 75), (75, 101)]

        var byFolder: [String: [Classifier.Decision]] = [:]
        for d in decisions {
            byFolder[d.folder, default: []].append(d)
        }

        let total = decisions.count
        for (folder, folderDecisions) in byFolder {
            let folderProportion = Double(folderDecisions.count) / Double(total)
            let folderQuota = max(1, Int((folderProportion * Double(n)).rounded()))

            for (lo, hi) in bins {
                let inBin = folderDecisions.filter { $0.confidence >= lo && $0.confidence < hi }
                guard !inBin.isEmpty else { continue }

                let binProportion = Double(inBin.count) / Double(folderDecisions.count)
                let binQuota = max(1, Int((binProportion * Double(folderQuota)).rounded()))

                var rng = SeededRNG(seed: seed &+ UInt64(bitPattern: Int64(folder.hashValue)) &+ UInt64(lo))
                var shuffled = inBin
                for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                    let j = Int(rng.next() % UInt64(i + 1))
                    shuffled.swapAt(i, j)
                }
                strata.append(Array(shuffled.prefix(binQuota)))
            }
        }

        var allSelected: [Classifier.Decision] = []
        for stratum in strata {
            allSelected.append(contentsOf: stratum)
        }

        var rng = SeededRNG(seed: seed &+ 999)
        for i in stride(from: allSelected.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            allSelected.swapAt(i, j)
        }
        allSelected = Array(allSelected.prefix(n))

        return allSelected.compactMap { d in
            guard let b = bookmarkMap[d.bookmarkID] else { return nil }
            return SampleRow(
                bookmarkID: d.bookmarkID,
                title: b.title,
                url: b.url,
                domain: b.domain,
                assignedFolder: d.folder,
                confidence: d.confidence
            )
        }
    }

    public static func toCSV(_ rows: [SampleRow]) -> String {
        var csv = "bookmark_id,title,url,domain,assigned_folder,confidence,verdict,note\n"
        for r in rows {
            csv += "\(r.bookmarkID),\(csvField(r.title)),\(csvField(r.url)),\(csvField(r.domain)),\(r.assignedFolder),\(r.confidence),\(r.verdict),\(r.note)\n"
        }
        return csv
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
