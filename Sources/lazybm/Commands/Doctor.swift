import ArgumentParser
import LazyBookmarksKit

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that the on-device model is available and ready."
    )

    @Flag(name: .customLong("download-assets"), help: "Download and compile the contextual embedding model up front.")
    var downloadAssets = false

    func run() async throws {
        let factory = SessionFactory()
        switch factory.availability() {
        case .available:
            let ctx = factory.contextSize()
            print("✓ On-device model available.")
            print("  Context window: \(ctx) tokens.")
        case .unavailable(let reason):
            print("✗ On-device model unavailable.")
            print("  \(reason)")
            throw ExitCode.failure
        }

        // Report embedder status
        if let embedder = EmbedderFactory.makeBest() {
            let family = embedder.modelID.hasPrefix("contextual") ? "contextual" : "sentence"
            print("\nEmbedding:")
            print("  Backend:  \(family)")
            print("  modelID:  \(embedder.modelID)")
            print("  dimension: \(embedder.dimension)")

            if let ctx = embedder as? ContextualEmbedder {
                let hasLatin = ctx.hasAssets(for: .latin)
                print("  Latin assets: \(hasLatin ? "ready" : "not ready")")
                if downloadAssets && !hasLatin {
                    print("  Requesting assets (this may download hundreds of MB)…")
                    let ok = await withCheckedContinuation { cont in
                        ctx.requestAssetsAsync(for: .latin) { success in
                            cont.resume(returning: success)
                        }
                    }
                    if ok {
                        print("  ✓ Assets ready.")
                        // Force a load to trigger first-run compilation
                        do {
                            _ = try ctx.vector(for: "warm up")
                            print("  ✓ Model compiled.")
                        } catch {
                            print("  ✗ Model compilation failed: \(error)")
                        }
                    } else {
                        print("  ✗ Asset request failed.")
                    }
                } else if downloadAssets && hasLatin {
                    // Trigger a load to ensure compilation happened
                    do {
                        _ = try ctx.vector(for: "warm up")
                        print("  ✓ Model compiled and ready.")
                    } catch {
                        print("  ✗ Model compilation failed: \(error)")
                    }
                }
            } else if embedder is SentenceEmbedder {
                print("  (Legacy sentence embedding — consider installing contextual assets.)")
            }
        } else {
            print("\n✗ No embedder available.")
        }
    }
}
