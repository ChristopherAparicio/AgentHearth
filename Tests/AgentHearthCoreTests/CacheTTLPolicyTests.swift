import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CacheTTLPolicyTests: XCTestCase {
    func testOpenAIModelsWithDocumentedTTL() {
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(openAIModel: "gpt-5.6-sol"), 30 * 60)
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(openAIModel: "GPT-5.6"), 30 * 60)
        XCTAssertTrue(CacheTTLPolicy.hasDocumentedTTL(openAIModel: "gpt-5.6-sol"))
    }

    func testOpenAIModelsWithoutDocumentedTTLFallBack() {
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(openAIModel: "gpt-5.5"), 5 * 60)
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(openAIModel: nil), 5 * 60)
        XCTAssertFalse(CacheTTLPolicy.hasDocumentedTTL(openAIModel: nil))
    }

    func testProviderQualifiedTTLRequiresOpenAI() {
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(provider: "openai", model: "gpt-5.6-sol"), 30 * 60)
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(provider: "OpenAI", model: "gpt-5.6-sol"), 30 * 60)
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(provider: "anthropic", model: "gpt-5.6-sol"), 5 * 60)
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(provider: nil, model: "gpt-5.6-sol"), 5 * 60)
        XCTAssertEqual(CacheTTLPolicy.ttlSeconds(provider: "openai", model: "o4-mini"), 5 * 60)
    }
}
