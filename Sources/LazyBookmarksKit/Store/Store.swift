import Foundation
import GRDB

public struct Store: Sendable {

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
            try db.create(table: "runs", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source_path", .text).notNull()
                t.column("started_at", .datetime).notNull()
                t.column("taxonomy_json", .text)
                t.column("status", .text).notNull().defaults(to: "running")
            }

            try db.create(table: "bookmarks", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("run_id", .integer).notNull().references("runs")
                t.column("title", .text).notNull().defaults(to: "")
                t.column("url", .text).notNull()
                t.column("original_path_json", .text)
                t.column("added_at", .datetime)
                t.column("assigned_folder", .text)
                t.column("confidence", .integer)
                t.column("committed", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "snapshots", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("run_id", .integer).notNull().references("runs")
                t.column("created_at", .datetime).notNull()
                t.column("payload_json", .text).notNull()
            }

            try db.create(table: "link_status", ifNotExists: true) { t in
                t.primaryKey("bookmark_id", .text).references("bookmarks", onDelete: .cascade)
                t.column("status", .text).notNull()
                t.column("checked_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            try db.create(table: "embeddings", ifNotExists: true) { t in
                t.primaryKey("bookmark_id", .text).references("bookmarks", onDelete: .cascade)
                t.column("run_id", .integer).notNull().references("runs")
                t.column("model", .text).notNull()
                t.column("dim", .integer).notNull()
                t.column("vector", .blob).notNull()
            }
            try db.create(table: "clusters", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("run_id", .integer).notNull().references("runs")
                t.column("label", .text).notNull()
                t.column("rationale", .text).notNull().defaults(to: "")
                t.column("accepted", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "cluster_members", ifNotExists: true) { t in
                t.column("cluster_id", .integer).notNull().references("clusters", onDelete: .cascade)
                t.column("bookmark_id", .text).notNull().references("bookmarks", onDelete: .cascade)
                t.primaryKey(["cluster_id", "bookmark_id"])
            }
        }

        migrator.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE runs ADD COLUMN summary_json TEXT")
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "enrichments", ifNotExists: true) { t in
                t.primaryKey("bookmark_id", .text).references("bookmarks", onDelete: .cascade)
                t.column("meta_description", .text)
                t.column("is_dead_link", .boolean).notNull().defaults(to: false)
                t.column("http_status", .integer)
                t.column("fetched_at", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Embeddings cache

    public func cacheEmbeddings(_ vectors: [String: [Float]], runID: Int64, model: String) throws {
        try dbQueue.write { db in
            for (id, vec) in vectors {
                let blob = Clusterer.vectorToBlob(vec)
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO embeddings (bookmark_id, run_id, model, dim, vector)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [id, runID, model, vec.count, blob]
                )
            }
        }
    }

    public func loadEmbeddings(runID: Int64, model: String) throws -> [String: [Float]] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT bookmark_id, vector FROM embeddings WHERE run_id = ? AND model = ?
            """, arguments: [runID, model])
            var result: [String: [Float]] = [:]
            for row in rows {
                let id: String = row["bookmark_id"]
                let data: Data = row["vector"]
                result[id] = Clusterer.blobToVector(data)
            }
            return result
        }
    }

    public func loadEmbeddings(bookmarkIDs: Set<String>, model: String) throws -> [String: [Float]] {
        guard !bookmarkIDs.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = bookmarkIDs.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT bookmark_id, vector FROM embeddings
                WHERE model = ? AND bookmark_id IN (\(placeholders))
            """
            var args: [DatabaseValueConvertible] = [model as DatabaseValueConvertible]
            args.append(contentsOf: bookmarkIDs.map { $0 as DatabaseValueConvertible })
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var result: [String: [Float]] = [:]
            for row in rows {
                let id: String = row["bookmark_id"]
                let data: Data = row["vector"]
                result[id] = Clusterer.blobToVector(data)
            }
            return result
        }
    }

    // MARK: - Clusters

    public func saveClusters(_ clusters: [(label: String, rationale: String, memberIDs: [String], accepted: Bool)], runID: Int64) throws {
        try dbQueue.write { db in
            for c in clusters {
                try db.execute(
                    sql: "INSERT INTO clusters (run_id, label, rationale, accepted) VALUES (?, ?, ?, ?)",
                    arguments: [runID, c.label, c.rationale, c.accepted]
                )
                let clusterID = db.lastInsertedRowID
                for bid in c.memberIDs {
                    try db.execute(
                        sql: "INSERT INTO cluster_members (cluster_id, bookmark_id) VALUES (?, ?)",
                        arguments: [clusterID, bid]
                    )
                }
            }
        }
    }

    // MARK: - Runs

    public func createRun(sourcePath: String) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO runs (source_path, started_at, status) VALUES (?, ?, ?)",
                arguments: [sourcePath, Date(), "running"]
            )
            return db.lastInsertedRowID
        }
    }

    public func finishRun(_ runID: Int64, taxonomyJSON: String, summaryJSON: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE runs SET status = ?, taxonomy_json = ?, summary_json = ? WHERE id = ?
                """,
                arguments: ["completed", taxonomyJSON, summaryJSON, runID]
            )
        }
    }

    public func loadTaxonomy(runID: Int64) throws -> Taxonomy? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT taxonomy_json FROM runs WHERE id = ?
            """, arguments: [runID]) else { return nil }
            let json: String? = row["taxonomy_json"]
            guard let json, let data = json.data(using: .utf8), !data.isEmpty else { return nil }
            if let envelope = try? JSONDecoder().decode(TaxonomyEnvelope.self, from: data) {
                return Taxonomy(folders: envelope.folders)
            }
            if let names = try? JSONDecoder().decode([String].self, from: data) {
                return Taxonomy(folders: names.map { Taxonomy.Folder(name: $0, rationale: "") })
            }
            return nil
        }
    }

    // MARK: - Bookmarks

    public func upsert(_ bookmarks: [Bookmark], runID: Int64) throws {
        try dbQueue.write { db in
            for b in bookmarks {
                let pathJSON = try String(data: JSONEncoder().encode(b.originalFolderPath), encoding: .utf8)
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO bookmarks
                    (id, run_id, title, url, original_path_json, added_at, assigned_folder, confidence, committed)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        b.id, runID, b.title, b.url, pathJSON, b.addedAt,
                        b.assignedFolder, b.confidence, false
                    ]
                )
            }
        }
    }

    public func uncommitted(runID: Int64) throws -> [Bookmark] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM bookmarks WHERE run_id = ? AND committed = 0 ORDER BY rowid
            """, arguments: [runID])
            return rows.map(Self.bookmarkFromRow)
        }
    }

    public func commit(_ decisions: [Classifier.Decision], runID: Int64) throws {
        try dbQueue.write { db in
            for d in decisions {
                try db.execute(
                    sql: """
                    UPDATE bookmarks SET assigned_folder = ?, confidence = ?, committed = 1
                    WHERE id = ? AND run_id = ?
                    """,
                    arguments: [d.folder, d.confidence, d.bookmarkID, runID]
                )
            }
        }
    }

    public func all(runID: Int64) throws -> [Bookmark] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM bookmarks WHERE run_id = ? ORDER BY rowid
            """, arguments: [runID])
            return rows.map(Self.bookmarkFromRow)
        }
    }

    // MARK: - Snapshots (undo)

    public func snapshot(runID: Int64) throws {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, assigned_folder, confidence, committed FROM bookmarks WHERE run_id = ?
            """, arguments: [runID])
            let payload = rows.map { row in
                [
                    "id": row["id"] as String,
                    "folder": (row["assigned_folder"] as String?) ?? "",
                    "confidence": row["confidence"] as Int? ?? 0,
                    "committed": row["committed"] as Bool
                ] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            try db.execute(
                sql: "INSERT INTO snapshots (run_id, created_at, payload_json) VALUES (?, ?, ?)",
                arguments: [runID, Date(), json]
            )
        }
    }

    public func undoLast(runID: Int64) throws -> Bool {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, payload_json FROM snapshots WHERE run_id = ? ORDER BY id DESC LIMIT 1
            """, arguments: [runID]) else {
                return false
            }
            let snapID: Int64 = row["id"]
            let json: String = row["payload_json"]
            guard let data = json.data(using: .utf8),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return false
            }
            for item in payload {
                guard let id = item["id"] as? String else { continue }
                let folder = (item["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let conf = item["confidence"] as? Int ?? 0
                let committed = item["committed"] as? Bool ?? false
                try db.execute(
                    sql: """
                    UPDATE bookmarks SET assigned_folder = ?, confidence = ?, committed = ?
                    WHERE id = ? AND run_id = ?
                    """,
                    arguments: [folder, conf, committed, id, runID]
                )
            }
            try db.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [snapID])
            return true
        }
    }

    // MARK: - Link status

    public func setLinkStatus(bookmarkID: String, status: LinkChecker.Status, checkedAt: Date = .now) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO link_status (bookmark_id, status, checked_at)
                VALUES (?, ?, ?)
                """,
                arguments: [bookmarkID, status.rawValue, checkedAt]
            )
        }
    }

    // MARK: - Enrichments

    public func getEnrichment(bookmarkID: String) throws -> Enrichment? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM enrichments WHERE bookmark_id = ?
            """, arguments: [bookmarkID]) else { return nil }
            return Self.enrichmentFromRow(row)
        }
    }

    public func getEnrichments(bookmarkIDs: Set<String>) throws -> [String: Enrichment] {
        guard !bookmarkIDs.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let placeholders = bookmarkIDs.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT * FROM enrichments WHERE bookmark_id IN (\(placeholders))
            """
            let args = StatementArguments(bookmarkIDs.map { $0 as DatabaseValueConvertible })!
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            var result: [String: Enrichment] = [:]
            for row in rows {
                let e = Self.enrichmentFromRow(row)
                result[e.bookmarkID] = e
            }
            return result
        }
    }

    public func setEnrichment(_ enrichment: Enrichment) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO enrichments (bookmark_id, meta_description, is_dead_link, http_status, fetched_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    enrichment.bookmarkID,
                    enrichment.metaDescription,
                    enrichment.isDeadLink,
                    enrichment.httpStatus,
                    enrichment.fetchedAt,
                ]
            )
        }
    }

    public func clearEnrichments() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM enrichments")
        }
    }

    // MARK: - Helpers

    private static func enrichmentFromRow(_ row: Row) -> Enrichment {
        Enrichment(
            bookmarkID: row["bookmark_id"],
            metaDescription: row["meta_description"],
            isDeadLink: row["is_dead_link"],
            httpStatus: row["http_status"],
            fetchedAt: row["fetched_at"]
        )
    }

    private static func bookmarkFromRow(_ row: Row) -> Bookmark {
        let pathJSON: String? = row["original_path_json"]
        let path: [String] = {
            guard let json = pathJSON, let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }()
        return Bookmark(
            id: row["id"],
            title: row["title"],
            url: row["url"],
            originalFolderPath: path,
            addedAt: row["added_at"],
            assignedFolder: row["assigned_folder"],
            confidence: row["confidence"]
        )
    }
}
