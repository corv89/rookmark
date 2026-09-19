import Foundation
import Testing

@testable import RookmarkApp

/// `Sources/RookmarkApp/Resources/consolidated-taxonomy-v5.json` is a manual
/// copy of `tuning/consolidated-taxonomy-v5.json`, and nothing in the build
/// copies it. Editing tuning/ without re-copying therefore ships a stale
/// taxonomy while the decode-level tests all pass (each file is
/// self-consistent). Compared as bytes so any divergence fails, not just
/// semantic ones.
@Suite("Bundled taxonomy copy integrity")
struct TaxonomyCopyIntegrityTests {

    /// Repo root located the same way the loader's DEBUG tier does: relative
    /// to this file (…/Tests/RookmarkAppTests → up three).
    private static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()     // Tests/RookmarkAppTests
        .deletingLastPathComponent()     // Tests
        .deletingLastPathComponent()     // repo root
    private static let tuningCopy = repoRoot
        .appending(path: "tuning/consolidated-taxonomy-v5.json")

    @Test(
        "bundled copy is byte-identical to tuning/consolidated-taxonomy-v5.json",
        .skip(
            if: !FileManager.default.fileExists(
                atPath: TaxonomyCopyIntegrityTests.tuningCopy.path(percentEncoded: false)
            ),
            "no tuning/ checkout beside the test bundle — app bundle only, nothing to compare"
        )
    )
    func bundledCopyMatchesTuning() throws {
        let bundled = try #require(
            Bundle.module.url(forResource: "consolidated-taxonomy-v5", withExtension: "json")
        )
        let tuning = try Data(contentsOf: Self.tuningCopy)
        let resources = try Data(contentsOf: bundled)
        #expect(
            tuning == resources,
            "Sources/RookmarkApp/Resources/consolidated-taxonomy-v5.json differs from tuning/consolidated-taxonomy-v5.json — re-copy the file before shipping"
        )
    }
}
