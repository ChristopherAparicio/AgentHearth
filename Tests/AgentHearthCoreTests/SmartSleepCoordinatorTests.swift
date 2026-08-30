import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

@MainActor
final class SmartSleepCoordinatorTests: XCTestCase {
    func testHoldsAssertionOnlyForEligibleWork() {
        let assertion = FakeSleepAssertion()
        let coordinator = SmartSleepCoordinator(assertion: assertion)
        coordinator.setMode(.keepAwake)

        coordinator.reconcile(sessions: [session(status: .idle)])
        XCTAssertFalse(assertion.isActive)

        coordinator.reconcile(sessions: [session(status: .working)])
        XCTAssertTrue(assertion.isActive)

        coordinator.reconcile(sessions: [session(status: .completed)])
        XCTAssertFalse(assertion.isActive)
    }

    func testTurningModeOffReleasesAssertion() {
        let assertion = FakeSleepAssertion()
        let coordinator = SmartSleepCoordinator(assertion: assertion)
        coordinator.setMode(.night)
        coordinator.reconcile(sessions: [session(status: .waitingForApproval)])
        XCTAssertTrue(assertion.isActive)

        coordinator.setMode(.off)
        XCTAssertFalse(assertion.isActive)
    }

    func testExpirationReleasesAssertionEvenWhenWorkContinues() {
        let assertion = FakeSleepAssertion()
        let coordinator = SmartSleepCoordinator(assertion: assertion)
        let now = Date(timeIntervalSince1970: 1_000)
        coordinator.setMode(.night, expiresAt: now.addingTimeInterval(60))

        coordinator.reconcile(sessions: [session(status: .working)], now: now)
        XCTAssertTrue(assertion.isActive)

        coordinator.reconcile(sessions: [session(status: .working)], now: now.addingTimeInterval(60))
        XCTAssertFalse(assertion.isActive)
        XCTAssertEqual(coordinator.mode, .off)
        XCTAssertNil(coordinator.expiresAt)
    }

    func testExpirationCanBeChangedWithoutChangingMode() {
        let assertion = FakeSleepAssertion()
        let coordinator = SmartSleepCoordinator(assertion: assertion)
        let deadline = Date(timeIntervalSince1970: 2_000)
        coordinator.setMode(.keepAwake)

        coordinator.setExpiration(deadline)

        XCTAssertEqual(coordinator.mode, .keepAwake)
        XCTAssertEqual(coordinator.expiresAt, deadline)
    }

    private func session(status: SessionStatus) -> AgentSession {
        AgentSession(
            id: UUID().uuidString,
            providerID: .codex,
            title: "Test",
            status: status,
            lastActivityAt: .now
        )
    }
}

@MainActor
private final class FakeSleepAssertion: SleepAssertionControlling {
    private(set) var isActive = false

    func acquire(reason: String) {
        isActive = true
    }

    func release() {
        isActive = false
    }
}
