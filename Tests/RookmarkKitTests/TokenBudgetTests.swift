import Testing
@testable import RookmarkKit

@Suite("TokenBudget")
struct TokenBudgetTests {

    @Test("inputBudget subtracts output reserve from total")
    func inputBudget() {
        let budget = TokenBudget(total: 4096, outputReserve: 768)
        #expect(budget.inputBudget == 3328)
    }

    @Test("inputBudget is never negative")
    func noNegative() {
        let budget = TokenBudget(total: 100, outputReserve: 200)
        #expect(budget.inputBudget == 0)
    }

    @Test("estimate returns at least 1 for non-empty text")
    func estimateMin() {
        let budget = TokenBudget(total: 4096)
        #expect(budget.estimate("x") >= 1)
    }

    @Test("estimate scales with text length")
    func estimateScales() {
        let budget = TokenBudget(total: 4096)
        let short = budget.estimate("hello")
        let long = budget.estimate(String(repeating: "word ", count: 100))
        #expect(long > short)
    }

    @Test("fits returns true when within budget")
    func fitsTrue() {
        let budget = TokenBudget(total: 4096, outputReserve: 768)
        #expect(budget.fits(instructions: "Sort bookmarks.", prompt: "Item: test"))
    }

    @Test("fits returns false when exceeding budget")
    func fitsFalse() {
        let budget = TokenBudget(total: 100, outputReserve: 50)
        let bigText = String(repeating: "x", count: 1000)
        #expect(!budget.fits(instructions: bigText, prompt: bigText))
    }

    @Test("default output reserve is 768")
    func defaultReserve() {
        let budget = TokenBudget(total: 4096)
        #expect(budget.outputReserve == 768)
    }
}
