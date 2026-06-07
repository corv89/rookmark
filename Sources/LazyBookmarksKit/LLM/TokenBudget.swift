import Foundation
import FoundationModels

/// Token accounting against the on-device model's 4 096-token window.
///
/// Apple notes the error can fire even when input alone is < 4 096, because the
/// model must also fit its *response* in the same window — so we always reserve
/// output headroom. Until `tokenCount(for:)` (26.4+) is wired in, a ~4 chars/token
/// heuristic is used; it is deliberately conservative.
public struct TokenBudget: Sendable {

    public let total: Int
    /// Tokens held back for the model's structured response.
    public let outputReserve: Int

    public init(total: Int, outputReserve: Int = 768) {
        self.total = total
        self.outputReserve = outputReserve
    }

    /// Tokens available for instructions + prompt combined.
    public var inputBudget: Int { max(0, total - outputReserve) }

    public func estimate(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 3.5).rounded(.up)))
    }

    @available(macOS 26.4, *)
    public func preciseTokenCount(_ text: String) async throws -> Int {
        try await SystemLanguageModel.default.tokenCount(for: text)
    }

    /// Whether `instructions + prompt` fits with output headroom to spare.
    public func fits(instructions: String, prompt: String) -> Bool {
        estimate(instructions) + estimate(prompt) <= inputBudget
    }
}
