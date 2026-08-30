import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class AdaptivePollingPolicyTests: XCTestCase {
    private let policy = AdaptivePollingPolicy()

    func testUsesFastPollingOnlyWhileAnAgentWorks() {
        XCTAssertEqual(policy.interval(for: [snapshot(.working)]), 5)
        XCTAssertEqual(policy.interval(for: [snapshot(.waitingForApproval)]), 10)
        XCTAssertEqual(policy.interval(for: [snapshot(.idle)]), 20)
        XCTAssertEqual(policy.interval(for: []), 30)
    }

    private func snapshot(_ status: SessionStatus) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .codex,
            connectionState: .connected,
            sessions: [AgentSession(
                id: "session",
                providerID: .codex,
                title: "Session",
                status: status,
                lastActivityAt: .now
            )],
            usageWindows: []
        )
    }
}
