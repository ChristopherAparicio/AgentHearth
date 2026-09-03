import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class SessionDisplayPolicyTests: XCTestCase {
    func testKeepsRecentSessionsAndLimitsEachProviderList() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = SessionDisplayPolicy(window: .oneDay, maximumPerProvider: 2)
        let sessions = [
            session("recent", at: now.addingTimeInterval(-60)),
            session("older", at: now.addingTimeInterval(-120)),
            session("expired", at: now.addingTimeInterval(-86_401)),
        ]

        XCTAssertEqual(policy.sessions(from: sessions, now: now).map(\.id), ["recent", "older"])
    }

    func testKeepsWorkingSessionOutsideTheRecentWindow() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = SessionDisplayPolicy(window: .oneDay, maximumPerProvider: 5)
        let staleWorking = session("working", at: now.addingTimeInterval(-172_800), status: .working)

        XCTAssertEqual(policy.sessions(from: [staleWorking], now: now).map(\.id), ["working"])
    }

    func testRanksPinnedSessionsAboveEveryStatusGroup() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = SessionDisplayPolicy(
            window: .oneDay,
            maximumPerProvider: 5,
            pinned: [PrioritySessionRef(providerID: .codex, hostID: AgentHost.local.id, sessionID: "pinned-idle")]
        )
        let sessions = [
            session("working", at: now.addingTimeInterval(-60), status: .working),
            session("idle", at: now.addingTimeInterval(-60)),
            session("pinned-idle", at: now.addingTimeInterval(-120)),
        ]

        XCTAssertEqual(
            policy.sessions(from: sessions, now: now).map(\.id),
            ["pinned-idle", "working", "idle"]
        )
    }

    private func session(_ id: String, at date: Date, status: SessionStatus = .idle) -> AgentSession {
        AgentSession(id: id, providerID: .codex, title: id, status: status, lastActivityAt: date)
    }
}
