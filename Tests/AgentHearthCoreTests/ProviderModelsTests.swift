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

    /// Titles are prompt-derived on some providers and end up in notifications
    /// and the on-disk history, so every source must pass through one cap.
    func testSessionTitleIsCappedCollapsedAndFallsBack() {
        let pasted = String(repeating: "secret prompt text ", count: 40)
        XCTAssertEqual(SessionTitle.normalized(pasted, fallback: "id").count, SessionTitle.maximumLength)
        XCTAssertEqual(SessionTitle.normalized("  line one \n\n  line two  ", fallback: "id"), "line one line two")
        XCTAssertEqual(SessionTitle.normalized("   \n ", fallback: "session-1"), "session-1")
        XCTAssertEqual(SessionTitle.normalized(nil, fallback: "session-1"), "session-1")
        XCTAssertEqual(SessionTitle.normalized("Fix the build", fallback: "id"), "Fix the build")
    }
}

