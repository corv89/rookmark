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

/// The model side of folder editing: rename-follows-rows, delete-falls-back-
/// to-Unsorted, merge, duplicate rejection (canonical, like the classifier's
/// own matching), and Unsorted protection. Runs with `persistingSessions:
/// false` so no test ever writes the host's real `session.json`.
@Suite("Taxonomy editing")
@MainActor
struct TaxonomyEditingTests {

    /// Two working folders plus one row each, and an Unsorted row whose
    /// modelChoice explains what the classifier originally picked.
    private func seededModel() -> OrganizerModel {
        let model = OrganizerModel(persistingSessions: false)
        model.updateWorkingTaxonomy([
            .init(name: "Development", rationale: "Code things."),
            .init(name: "Reading", rationale: "Long reads."),
        ])
        model.updateRows([
            .init(id: "a", title: "A", url: "https://rookmark-taxonomy-test.invalid/a",
                  folder: "Development", confidence: 90, modelChoice: nil),
            .init(id: "b", title: "B", url: "https://rookmark-taxonomy-test.invalid/b",
                  folder: "Reading", confidence: 80, modelChoice: nil),
            .init(id: "c", title: "C", url: "https://rookmark-taxonomy-test.invalid/c",
                  folder: Taxonomy.unsorted, confidence: 55, modelChoice: "Development"),
        ])
        return model
    }

    /// Runs one edit and returns the model's rejection, or nil when it passed.
    private func editError(
        _ model: OrganizerModel,
        _ edit: () throws -> Void
    ) -> OrganizerModel.TaxonomyEditError? {
        do {
            try edit()
            return nil
        } catch let error as OrganizerModel.TaxonomyEditError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }

    @Test("renaming a folder re-labels its rows and keeps the rationale")
    func renameFollowsRows() throws {
        let model = seededModel()

        try model.updateFolder("Development", to: "Coding", rationale: "Code things.")

        #expect(model.rows.first { $0.id == "a" }?.folder == "Coding")
        #expect(model.folders.contains { $0.name == "Coding" })
        #expect(!model.folders.contains { $0.name == "Development" })
        #expect(model.rationale(for: "Coding") == "Code things.")
        #expect(model.workingFolders.map(\.name) == ["Coding", "Reading"])
        // Judgement state rides along through the relabel.
        #expect(model.rows.first { $0.id == "a" }?.confidence == 90)
    }

    @Test("a case-only respelling of the same folder is allowed")
    func caseOnlyRenameSucceeds() throws {
        let model = seededModel()

        try model.updateFolder("Development", to: "development", rationale: "Ship it.")

        #expect(model.workingFolders.map(\.name) == ["development", "Reading"])
        #expect(model.rationale(for: "development") == "Ship it.")
        #expect(model.rows.first { $0.id == "a" }?.folder == "development")
    }

    @Test("deleting a folder falls its rows back to Unsorted")
    func deleteFallsBackToUnsorted() throws {
        let model = seededModel()

        try model.deleteFolder("Reading")

        #expect(!model.workingFolders.contains { $0.name == "Reading" })
        #expect(!model.folders.contains { $0.name == "Reading" })
        let row = model.rows.first { $0.id == "b" }
        #expect(row?.isUnsorted == true)
        // The decision itself is preserved so the inspector can still explain it.
        #expect(row?.confidence == 80)
        #expect(row?.accepted == true)
    }

    @Test("merging moves the rows and removes the source folder")
    func mergeMovesRows() throws {
        let model = seededModel()

        try model.mergeFolder("Reading", into: "Development")

        #expect(!model.workingFolders.contains { $0.name == "Reading" })
        #expect(!model.folders.contains { $0.name == "Reading" })
        #expect(model.rows.first { $0.id == "b" }?.folder == "Development")
        #expect(model.folders.first { $0.name == "Development" }?.count == 2)
    }

    @Test("duplicate folder names are rejected case-insensitively")
    func duplicatesRejected() {
        let model = seededModel()

        #expect(editError(model) { try model.addFolder(named: "DEVELOPMENT", rationale: "") }
            == .duplicateName("Development"))
        #expect(editError(model) { try model.updateFolder("Reading", to: "development", rationale: "") }
            == .duplicateName("Development"))
        #expect(model.workingFolders.count == 2)
    }

    @Test("the Unsorted sentinel cannot be deleted, renamed, or shadowed")
    func unsortedProtected() {
        let model = seededModel()

        #expect(editError(model) { try model.deleteFolder(Taxonomy.unsorted) } == .protectedFolder)
        #expect(editError(model) { try model.updateFolder(Taxonomy.unsorted, to: "X", rationale: "") }
            == .protectedFolder)
        #expect(editError(model) { try model.addFolder(named: "unsorted", rationale: "") }
            == .protectedFolder)
    }

    @Test("empty, unknown, and self-merge edits are rejected")
    func invalidEditsRejected() {
        let model = seededModel()

        #expect(editError(model) { try model.addFolder(named: "   ", rationale: "") } == .emptyName)
        #expect(editError(model) { try model.updateFolder("Development", to: "", rationale: "") }
            == .emptyName)
        #expect(editError(model) { try model.deleteFolder("Nonexistent") } == .unknownFolder)
        #expect(editError(model) { try model.updateFolder("Nonexistent", to: "X", rationale: "") }
            == .unknownFolder)
        #expect(editError(model) { try model.mergeFolder("Development", into: "Development") }
            == .sameFolder)
    }

    @Test("an added folder is immediately a move target with zero bookmarks")
    func addMakesEmptyFolderVisible() throws {
        let model = seededModel()

        try model.addFolder(named: "Recipes", rationale: "Food.")

        let added = model.folders.first { $0.name == "Recipes" }
        #expect(added != nil)
        #expect(added?.count == 0)
        #expect(added?.rationale == "Food.")
    }

    @Test("the oversized warning trips only past the threshold")
    func oversizedWarning() {
        let model = OrganizerModel(persistingSessions: false)
        let base = (1...OrganizerModel.largeTaxonomyThreshold).map {
            Taxonomy.Folder(name: "F\($0)", rationale: "")
        }
        model.updateWorkingTaxonomy(base)
        #expect(model.workingFolders.count == OrganizerModel.largeTaxonomyThreshold)
        #expect(!model.isTaxonomyOversized)

        model.updateWorkingTaxonomy(base + [.init(name: "One too many", rationale: "")])
        #expect(model.isTaxonomyOversized)
    }

    @Test("discarding the session resets the taxonomy to the bundled list")
    func discardResetsTaxonomy() throws {
        let model = seededModel()
        try model.addFolder(named: "Recipes", rationale: "Food.")

        model.discardSession()

        #expect(model.rows.isEmpty)
        #expect(model.workingFolders == try OrganizerModel.loadPinnedTaxonomy().folders)
    }

    @Test("canonical names mirror the classifier's matching")
    func canonicalMirrorsClassifier() {
        #expect(OrganizerModel.canonicalFolderName(" Dev ") == "dev")
        #expect(OrganizerModel.canonicalFolderName("DEV") == OrganizerModel.canonicalFolderName("dev"))
    }
}

