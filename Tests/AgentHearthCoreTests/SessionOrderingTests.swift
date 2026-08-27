import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class SessionOrderingTests: XCTestCase {
    private func session(
        id: String,
        status: SessionStatus,
        lastActivityAt: Date
    ) -> AgentSession {
        AgentSession(
            id: id,
            providerID: .claudeCode,
            title: id,
            status: status,
            lastActivityAt: lastActivityAt
        )
    }

    func testWorkingSessionsSortBeforeMoreRecentNonWorkingOnes() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sorted = [
            session(id: "idle-recent", status: .idle, lastActivityAt: base.addingTimeInterval(600)),
            session(id: "working-old", status: .working, lastActivityAt: base),
        ].sortedWorkingFirst()

        XCTAssertEqual(sorted.map(\.id), ["working-old", "idle-recent"])
    }

    func testNonWorkingSessionsSortByMostRecentActivity() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sorted = [
            session(id: "failed-old", status: .failed, lastActivityAt: base),
            session(id: "approval-recent", status: .waitingForApproval, lastActivityAt: base.addingTimeInterval(300)),
            session(id: "idle-newest", status: .idle, lastActivityAt: base.addingTimeInterval(900)),
        ].sortedWorkingFirst()

        XCTAssertEqual(sorted.map(\.id), ["idle-newest", "approval-recent", "failed-old"])
    }

    func testWorkingSessionsSortByMostRecentActivityAmongThemselves() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let sorted = [
            session(id: "working-old", status: .working, lastActivityAt: base),
            session(id: "working-new", status: .working, lastActivityAt: base.addingTimeInterval(120)),
        ].sortedWorkingFirst()

        XCTAssertEqual(sorted.map(\.id), ["working-new", "working-old"])
    }
}
