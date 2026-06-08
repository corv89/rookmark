import Foundation
import FoundationModels

/// Wraps `SystemLanguageModel` lifecycle concerns: availability gating, the
/// 4 096-token context-size probe, and prewarmed session creation.
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

    /// 4 096 today and "no possibility of it changing" per Apple, but we never
    /// hardcode it at the call site — `contextSize()` is the source of truth.
    public static let fallbackContextSize = 4096

    public var generationOptions: GenerationOptions {
        GenerationOptions(sampling: .greedy, temperature: 0)
    }

    public init() {}

    /// Synchronous availability check suitable for `doctor` / preconditions.
    public func availability() -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "Unknown availability state.")
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
