import Foundation
import FoundationModels

/// Wraps `SystemLanguageModel` lifecycle concerns: availability gating, the
/// context-size probe, and prewarmed session creation.
///
/// NOTE on concurrency: the on-device model is a single shared system resource.
/// The framework effectively serializes inference, so spinning up many parallel
/// sessions yields little throughput and more memory pressure. Treat one warm
/// model + short batches as the design center; see ImplementationPlan.md.
public struct SessionFactory: Sendable {

    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(reason: String)
    }

    /// Why the on-device model is unavailable, as data rather than prose.
    /// Mirrors `SystemLanguageModel`'s UnavailableReason so consumers can
    /// branch on the cause — an ineligible Mac has no System Settings remedy —
    /// without matching `describe` strings. `unknown` covers future framework
    /// reasons.
    public enum UnavailableKind: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }

    /// The availability check with its cause attached: `Availability` plus
    /// the structured kind. `availability()` (prose only) stays for consumers
    /// that never branch on the reason — the CLI and Organizer's
    /// precondition; read this instead when a decision depends on the cause.
    public enum AvailabilityStatus: Sendable, Equatable {
        case available
        case unavailable(kind: UnavailableKind, reason: String)
    }

    /// Last-resort floor only. The window is NOT a constant: 4 096 was the
    /// documented figure, but macOS 27 reports 8 192. Always read `contextSize()`
    /// rather than assuming either — code that hardcodes one will either waste
    /// most of a larger window or overflow a smaller one.
    public static let fallbackContextSize = 4096

    public var generationOptions: GenerationOptions {
        GenerationOptions(sampling: .greedy, temperature: 0)
    }

    public init() {}

    /// Synchronous availability check with the structured cause. Same probe
    /// as `availability()`; one value carrying both the decision input and
    /// the display text.
    public func availabilityStatus() -> AvailabilityStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(kind: Self.kind(of: reason), reason: Self.describe(reason))
        @unknown default:
            return .unavailable(kind: .unknown, reason: "Unknown availability state.")
        }
    }

    /// Synchronous availability check suitable for `doctor` / preconditions.
    /// Prose only — a reason string for display. Callers that need to branch
    /// on the cause use `availabilityStatus()`.
    public func availability() -> Availability {
        switch availabilityStatus() {
        case .available:
            return .available
        case .unavailable(_, let reason):
            return .unavailable(reason: reason)
        }
    }

    static func kind(of reason: SystemLanguageModel.Availability.UnavailableReason) -> UnavailableKind {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .unknown
        }
    }

    public func contextSize() -> Int {
        SystemLanguageModel.default.contextSize
    }

    /// Creates a fresh, prewarmed session. We create one session *per batch*
    /// during classification so the transcript never accumulates against the
    /// tiny context budget.
    public func makeSession(instructions: String) -> LanguageModelSession {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        return session
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence (Apple Silicon required)."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Enable it in System Settings ▸ Apple Intelligence & Siri."
        case .modelNotReady:
            return "The on-device model is still downloading or warming up. Try again shortly."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }
}
