import Foundation
import RookmarkKit
import Testing

@testable import RookmarkApp

/// The snapshot is the only thing that carries a taxonomy edit across a
/// relaunch. It must also never strand a file written before folder editing
/// existed: the field is optional, so old JSON decodes with
/// `taxonomyFolders == nil` and the app restores against the pinned taxonomy.
/// Pure Codable — nothing here touches the host's real `session.json`.
@Suite("Session snapshot taxonomy")
struct SessionSnapshotTaxonomyTests {

    private func snapshot(
        taxonomyFolders: [Taxonomy.Folder]? = nil
    ) -> SessionStore.Snapshot {
        .init(savedAt: Date(timeIntervalSince1970: 0),
              sourceIDs: ["a"],
              rows: [],
              newFolders: [],
              completed: true,
              taxonomyFolders: taxonomyFolders)
    }

    @Test("an edited folder list round-trips through the snapshot JSON")
    func roundTrip() throws {
        let original = snapshot(taxonomyFolders: [
            .init(name: "Development", rationale: "Code things."),
            .init(name: "Reading", rationale: "Long reads."),
        ])

        let decoded = try JSONDecoder().decode(
            SessionStore.Snapshot.self, from: JSONEncoder().encode(original)
        )

        #expect(decoded.taxonomyFolders == original.taxonomyFolders)
        #expect(decoded.taxonomyFolders?.count == 2)
        #expect(decoded.taxonomyFolders?.first?.rationale == "Code things.")
    }

    @Test("a snapshot written before folder editing existed still loads")
    func oldSnapshotWithoutField() throws {
        let json = """
        {"savedAt":"2026-01-01T00:00:00Z","sourceIDs":["a"],"rows":[],"newFolders":[],"completed":true}
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // matches SessionStore.load
        let decoded = try decoder.decode(SessionStore.Snapshot.self, from: Data(json.utf8))

        #expect(decoded.taxonomyFolders == nil)
        #expect(decoded.completed == true)
    }

    @Test("a snapshot with no edited taxonomy omits the key entirely")
    func nilEncodesAsAbsentKey() throws {
        let data = try JSONEncoder().encode(snapshot())

        #expect(!String(decoding: data, as: UTF8.self).contains("taxonomyFolders"))
    }
}
