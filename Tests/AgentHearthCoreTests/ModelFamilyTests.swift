import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class ModelFamilyTests: XCTestCase {
    func testClaudeModelsAreAnthropic() {
        XCTAssertEqual(ModelFamily(modelID: "claude-sonnet-4-5"), .anthropic)
        XCTAssertEqual(ModelFamily(modelID: "anthropic/claude-3-7-sonnet"), .anthropic)
        XCTAssertEqual(ModelFamily(modelID: "CLAUDE-OPUS"), .anthropic)
    }

    func testOpenAIModelsAreOpenAI() {
        XCTAssertEqual(ModelFamily(modelID: "gpt-4o"), .openAI)
        XCTAssertEqual(ModelFamily(modelID: "GPT-5"), .openAI)
        XCTAssertEqual(ModelFamily(modelID: "o1-preview"), .openAI)
        XCTAssertEqual(ModelFamily(modelID: "o3-mini"), .openAI)
        XCTAssertEqual(ModelFamily(modelID: "openai/o4-mini"), .openAI)
    }

    func testClaudeWinsOverOpenAIFragments() {
        // "claude" is checked first, so an identifier containing both
        // classifies as Anthropic. Mirrors the original inline logic.
        XCTAssertEqual(ModelFamily(modelID: "claude-o1-hybrid"), .anthropic)
    }

    func testUnknownAndMissingModelsAreOther() {
        XCTAssertEqual(ModelFamily(modelID: "gemini-2.5-pro"), .other)
        XCTAssertEqual(ModelFamily(modelID: "llama-3.2-90b"), .other)
        XCTAssertEqual(ModelFamily(modelID: ""), .other)
        XCTAssertEqual(ModelFamily(modelID: nil), .other)
    }
}
