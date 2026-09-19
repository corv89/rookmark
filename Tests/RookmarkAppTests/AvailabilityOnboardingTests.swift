import RookmarkKit
import Testing

@testable import RookmarkApp

/// The kit owns the availability check; the app owns deciding what the UI does
/// with each reason. These tests pin that mapping — a structured `SessionFactory.AvailabilityStatus`
/// in, notice state out — so they run anywhere without the real model.
@Suite("Model availability onboarding")
@MainActor
struct AvailabilityOnboardingTests {

    /// Verbatim from `SessionFactory.describe` — they pin the pass-through
    /// display text; the mapping keys off the structured kind instead
    /// (see `mappingIgnoresWording`).
    private static let notEnabled = "Apple Intelligence is off. Enable it in System Settings ▸ Apple Intelligence & Siri."
    private static let ineligible = "This Mac isn't eligible for Apple Intelligence (Apple Silicon required)."
    private static let notReady = "The on-device model is still downloading or warming up. Try again shortly."

    private func unavailableParts(
        _ state: OrganizerModel.ModelAvailability
    ) -> (reason: String, showsSettingsLink: Bool)? {
        if case .unavailable(let reason, let showsSettingsLink) = state {
            return (reason, showsSettingsLink)
        }
        return nil
    }

    @Test("available maps to the plain ready state")
    func availableIsReady() {
        #expect(OrganizerModel.ModelAvailability(.available) == .available)
    }

    @Test("Apple Intelligence off keeps the reason and points at the pane")
    func notEnabledShowsSettingsLink() throws {
        let parts = try #require(unavailableParts(.init(.unavailable(kind: .appleIntelligenceNotEnabled, reason: Self.notEnabled))))
        #expect(parts.reason == Self.notEnabled)
        #expect(parts.showsSettingsLink)
    }

    @Test("an ineligible Mac gets no settings button — nothing to enable")
    func ineligibleHasNoSettingsButton() throws {
        let parts = try #require(unavailableParts(.init(.unavailable(kind: .deviceNotEligible, reason: Self.ineligible))))
        #expect(parts.reason == Self.ineligible)
        #expect(!parts.showsSettingsLink)
    }

    @Test("model-not-ready still offers the pane, where the download shows")
    func notReadyShowsSettingsLink() throws {
        let parts = try #require(unavailableParts(.init(.unavailable(kind: .modelNotReady, reason: Self.notReady))))
        #expect(parts.showsSettingsLink)
    }

    /// The activation re-check contract, exercised through the property path
    /// rather than the framework: a user who enables Apple Intelligence
    /// mid-session must see the notice clear without relaunching.
    @Test("re-checking availability clears the blocked state in place")
    func updatePathClearsBlockedState() {
        let model = OrganizerModel()
        #expect(model.isModelAvailable)

        model.updateAvailability(.unavailable(kind: .appleIntelligenceNotEnabled, reason: Self.notEnabled))
        #expect(!model.isModelAvailable)
        #expect(unavailableParts(model.modelAvailability)?.showsSettingsLink == true)

        model.updateAvailability(.available)
        #expect(model.isModelAvailable)
        #expect(model.modelAvailability == .available)
    }

    @Test("an unrecognized kind still offers the pane — the safe default")
    func unknownKindShowsSettingsLink() throws {
        let parts = try #require(unavailableParts(
            .init(.unavailable(kind: .unknown, reason: "The on-device model is unavailable."))
        ))
        #expect(parts.showsSettingsLink)
    }

    /// The regression this suite guards: the decision keys off the kind, so
    /// reworded kit prose can never silently re-enable the settings button.
    @Test("the decision keys off the kind, not the wording")
    func mappingIgnoresWording() throws {
        let parts = try #require(unavailableParts(
            .init(.unavailable(kind: .deviceNotEligible, reason: "Reworded notice."))
        ))
        #expect(!parts.showsSettingsLink)
    }
}
