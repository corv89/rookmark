import Foundation
import GRDB

public struct LabelStore: Sendable {

    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "labels", ifNotExists: true) { t in
                t.column("bookmark_id", .text).notNull()
                t.column("folder", .text).notNull()
                t.column("verdict", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "human")
                t.column("note", .text)
                t.column("labeled_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.primaryKey(["bookmark_id", "folder"])
            }
        }

        try migrator.migrate(dbQueue)
    }

    public func upsert(_ labels: [Label]) throws {
        try dbQueue.write { db in
            for label in labels {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO labels (bookmark_id, folder, verdict, source, note, labeled_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        label.bookmarkID,
                        label.folder,
                        label.verdict.rawValue,
                        label.source,
                        label.note,
                        label.labeledAt
                    ]
                )
            }
        }
    }

    public func allLabels() throws -> [Label] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bookmark_id, folder, verdict, source, note, labeled_at
                FROM labels
                ORDER BY labeled_at
            """)
            return rows.map { row in
                Label(
                    bookmarkID: row["bookmark_id"],
                    folder: row["folder"],
                    verdict: Verdict(rawValue: row["verdict"]) ?? .reject,
                    source: row["source"],
                    note: row["note"],
                    labeledAt: row["labeled_at"]
                )
            }
        }
    }

    public func labelsByKey() throws -> [LabelKey: Label] {
        let all = try allLabels()
        return Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }

    public func importCSV(_ data: Data) throws -> Int {
        guard var csv = String(data: data, encoding: .utf8) else { return 0 }
        csv = csv.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = Self.parseCSVLines(csv)
        guard lines.count > 1 else { return 0 }

        let header = lines[0].map { $0.trimmingCharacters(in: .whitespaces) }
        guard let bmIdx = header.firstIndex(of: "bookmark_id"),
              let folderIdx = header.firstIndex(of: "folder") ?? header.firstIndex(of: "assigned_folder"),
              let verdictIdx = header.firstIndex(of: "verdict") else {
            return 0
        }

        let sourceIdx = header.firstIndex(of: "source")
        let noteIdx = header.firstIndex(of: "note")

        var labels: [Label] = []
        for i in 1..<lines.count {
            let fields = lines[i]
            guard fields.count > max(bmIdx, folderIdx, verdictIdx) else { continue }

            let bookmarkID = fields[bmIdx].trimmingCharacters(in: .whitespaces)
            let folder = fields[folderIdx].trimmingCharacters(in: .whitespaces)
            let verdictStr = fields[verdictIdx].trimmingCharacters(in: .whitespaces)
            guard !bookmarkID.isEmpty, !folder.isEmpty, !verdictStr.isEmpty,
                  let verdict = Verdict(rawValue: verdictStr) else { continue }

            let source = sourceIdx.map { idx in fields.count > idx ? fields[idx].trimmingCharacters(in: .whitespaces) : "human" } ?? "human"
            let note = noteIdx.map { idx in
                fields.count > idx ? fields[idx].trimmingCharacters(in: .whitespaces) : ""
            }.flatMap { $0.isEmpty ? nil : $0 }

            labels.append(Label(
                bookmarkID: bookmarkID,
                folder: folder,
                verdict: verdict,
                source: source,
                note: note
            ))
        }

        try upsert(labels)
        return labels.count
    }

    private static func parseCSVLines(_ csv: String) -> [[String]] {
        var result: [[String]] = []
        var currentLine: [String] = []
        var currentField = ""
        var inQuotes = false

        for ch in csv {
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    currentLine.append(currentField)
                    currentField = ""
                } else if ch == "\n" {
                    if !currentField.isEmpty || !currentLine.isEmpty {
                        currentLine.append(currentField)
                        result.append(currentLine)
                        currentLine = []
                        currentField = ""
                    }
                } else {
                    currentField.append(ch)
                }
            }
        }
        if !currentField.isEmpty || !currentLine.isEmpty {
            currentLine.append(currentField)
            result.append(currentLine)
        }
        return result
    }

    public func exportCSV() throws -> Data {
        let labels = try allLabels()
        var csv = "bookmark_id,folder,verdict,source,note\n"
        for label in labels {
            csv += "\(label.bookmarkID),\(csvField(label.folder)),\(label.verdict.rawValue),\(label.source),\(label.note.map(csvField) ?? "")\n"
        }
        return Data(csv.utf8)
    }

    private func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
