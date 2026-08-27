import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class ProviderModelsTests: XCTestCase {
    func testUsageFractionIsClamped() {
        XCTAssertEqual(UsageWindow(id: "high", label: "High", usedFraction: 1.4).usedFraction, 1)
        XCTAssertEqual(UsageWindow(id: "low", label: "Low", usedFraction: -0.2).usedFraction, 0)
    }

    func testOnlyActionableStatesRequireAttention() {
        XCTAssertTrue(SessionStatus.waitingForApproval.requiresAttention)
        XCTAssertTrue(SessionStatus.stuck.requiresAttention)
        XCTAssertFalse(SessionStatus.working.requiresAttention)
        XCTAssertFalse(SessionStatus.completed.requiresAttention)
    }
}

