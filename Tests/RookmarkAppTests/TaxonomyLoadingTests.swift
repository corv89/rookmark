import Foundation
import RookmarkKit
import Testing

@testable import RookmarkApp

/// The shipped app must load its pinned taxonomy on any machine, not just a
/// checkout. `loadPinnedTaxonomy` reads the source tree first — a DEBUG-only
/// development convenience — and otherwise resolves through the bundled
/// copy, which is the only tier in a release build; these tests pin both
/// halves of that contract so the app cannot regress to dead-on-arrival.
@Suite("Pinned taxonomy loading")
struct TaxonomyLoadingTests {

    @Test("the app's loader yields folders plus the Unsorted sentinel")
    @MainActor
    func appLoaderSucceeds() throws {
        let taxonomy = try OrganizerModel.loadPinnedTaxonomy()

        #expect(!taxonomy.folders.isEmpty)
        // The JSON carries no Unsorted folder; the sentinel joins via
        // allowedFolderNames, which is the set the classifier targets.
        #expect(taxonomy.allowedFolderNames.contains(Taxonomy.unsorted))
    }

    /// The shipping tier on its own: in a checkout the loader finds `tuning/`
    /// first, so this is the only way to prove the copy a distributed
    /// Rookmark.app actually relies on exists and decodes.
    @Test("the bundled resource exists and decodes through TaxonomyEnvelope")
    func bundledCopyDecodes() throws {
        let url = try #require(
            Bundle.module.url(forResource: "consolidated-taxonomy-v5", withExtension: "json")
        )
        let envelope = try JSONDecoder().decode(TaxonomyEnvelope.self, from: try Data(contentsOf: url))
        #expect(!envelope.folders.isEmpty)
    }
}
