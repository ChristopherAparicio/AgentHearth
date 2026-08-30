import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class SnapshotAlertDetectorTests: XCTestCase {
    func testDoesNotAlertOnInitialBaselineThenDetectsTransitions() async {
        let detector = SnapshotAlertDetector()
        let initial = snapshot(status: .working, cacheRemaining: 120, usage: 0.70)
        let initialAlerts = await detector.detect(in: [initial], preferences: AlertPreferences())
        XCTAssertTrue(initialAlerts.isEmpty)

        let changed = snapshot(status: .waitingForApproval, cacheRemaining: 45, usage: 0.82)
        let alerts = await detector.detect(in: [changed], preferences: AlertPreferences())

        XCTAssertEqual(Set(alerts.map(\.type)), ["session.waitingForApproval", "cache.expiring", "usage.limit"])
    }

    func testDisabledNotificationsStillAdvanceBaseline() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.70)], preferences: AlertPreferences())
        var disabled = AlertPreferences()
        disabled.notificationsEnabled = false
        let disabledAlerts = await detector.detect(
            in: [snapshot(status: .failed, cacheRemaining: 30, usage: 0.90)],
            preferences: disabled
        )
        XCTAssertTrue(disabledAlerts.isEmpty)
        let reenabledAlerts = await detector.detect(
            in: [snapshot(status: .failed, cacheRemaining: 30, usage: 0.90)],
            preferences: AlertPreferences()
        )
        XCTAssertTrue(reenabledAlerts.isEmpty)
    }

    func testAlertsWhenAnExpiringCacheIsFirstDiscovered() async {
        let detector = SnapshotAlertDetector()
        let alerts = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 45, usage: 0.20)],
            preferences: AlertPreferences()
        )

        XCTAssertEqual(alerts.map(\.type), ["cache.expiring"])
    }

    func testWorkingToIdleProducesCompletionAlert() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.20)],
            preferences: AlertPreferences()
        )

        let alerts = await detector.detect(
            in: [snapshot(status: .idle, cacheRemaining: 110, usage: 0.21)],
            preferences: AlertPreferences()
        )

        XCTAssertEqual(alerts.map(\.type), ["session.completed"])
    }

    func testPriorityOnlyFiltersSessionAlertsToPinnedSessions() async {
        let detector = SnapshotAlertDetector()
        let unpinnedFocus = focus(mode: .priorityOnly, ask: false)
        _ = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.70)],
            preferences: AlertPreferences(),
            focus: unpinnedFocus
        )

        let alerts = await detector.detect(
            in: [snapshot(status: .waitingForApproval, cacheRemaining: 45, usage: 0.82)],
            preferences: AlertPreferences(),
            focus: unpinnedFocus
        )

        // Attention and cache alerts are muted for the unpinned session, but
        // the account-wide usage alert is never filtered.
        XCTAssertEqual(alerts.map(\.type), ["usage.limit"])
    }

    func testPriorityOnlyKeepsSessionAlertsForPinnedSessions() async {
        let detector = SnapshotAlertDetector()
        let pinnedFocus = focus(mode: .priorityOnly, ask: false, pinned: [sessionRef])
        _ = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.70)],
            preferences: AlertPreferences(),
            focus: pinnedFocus
        )

        let alerts = await detector.detect(
            in: [snapshot(status: .waitingForApproval, cacheRemaining: 45, usage: 0.82)],
            preferences: AlertPreferences(),
            focus: pinnedFocus
        )

        XCTAssertEqual(Set(alerts.map(\.type)), ["session.waitingForApproval", "cache.expiring", "usage.limit"])
    }

    func testPriorityOnlyFiltersInitialCacheAlertToPinnedSessions() async {
        let unpinnedDetector = SnapshotAlertDetector()
        let unpinnedAlerts = await unpinnedDetector.detect(
            in: [snapshot(status: .idle, cacheRemaining: 45, usage: 0.20)],
            preferences: AlertPreferences(),
            focus: focus(mode: .priorityOnly, ask: false)
        )
        XCTAssertTrue(unpinnedAlerts.isEmpty)

        let pinnedDetector = SnapshotAlertDetector()
        let pinnedAlerts = await pinnedDetector.detect(
            in: [snapshot(status: .idle, cacheRemaining: 45, usage: 0.20)],
            preferences: AlertPreferences(),
            focus: focus(mode: .priorityOnly, ask: false, pinned: [sessionRef])
        )
        XCTAssertEqual(pinnedAlerts.map(\.type), ["cache.expiring"])
    }

    func testPromoteAskFiresForNewActiveSessionInPriorityOnly() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [], preferences: AlertPreferences(), focus: focus(mode: .priorityOnly))

        let alerts = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.20)],
            preferences: AlertPreferences(),
            focus: focus(mode: .priorityOnly)
        )

        XCTAssertEqual(alerts.map(\.type), ["session.promote"])
        XCTAssertEqual(alerts.first?.severity, .information)
        XCTAssertEqual(alerts.first?.title, "New session started")
        XCTAssertNotNil(alerts.first?.sessionTarget)
    }

    func testPromoteAskDoesNotFireWhenPinnedOrModeAllOrAskDisabledOrIdle() async {
        let scenarios: [(SessionFocusPreferences, SessionStatus)] = [
            (focus(mode: .priorityOnly, pinned: [sessionRef]), .working),
            (focus(mode: .all), .working),
            (focus(mode: .priorityOnly, ask: false), .working),
            (focus(mode: .priorityOnly), .idle),
        ]
        for (scenario, status) in scenarios {
            let detector = SnapshotAlertDetector()
            _ = await detector.detect(in: [], preferences: AlertPreferences(), focus: scenario)
            let alerts = await detector.detect(
                in: [snapshot(status: status, cacheRemaining: 120, usage: 0.20)],
                preferences: AlertPreferences(),
                focus: scenario
            )
            XCTAssertFalse(alerts.contains { $0.type == "session.promote" })
        }
    }

    func testPromoteAskFiresAgainWhenACompletedSessionBecomesActive() async {
        let detector = SnapshotAlertDetector()
        let priorityFocus = focus(mode: .priorityOnly)
        _ = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.20)],
            preferences: AlertPreferences(),
            focus: priorityFocus
        )

        let completedAlerts = await detector.detect(
            in: [snapshot(status: .completed, cacheRemaining: 120, usage: 0.20)],
            preferences: AlertPreferences(),
            focus: priorityFocus
        )
        XCTAssertTrue(completedAlerts.isEmpty)

        let reactivatedAlerts = await detector.detect(
            in: [snapshot(status: .working, cacheRemaining: 120, usage: 0.20)],
            preferences: AlertPreferences(),
            focus: priorityFocus
        )
        XCTAssertEqual(reactivatedAlerts.map(\.type), ["session.promote"])
    }

    private var sessionRef: PrioritySessionRef {
        PrioritySessionRef(providerID: .codex, hostID: AgentHost.local.id, sessionID: "session-1")
    }

    private func focus(
        mode: NotificationFocusMode,
        ask: Bool = true,
        pinned: [PrioritySessionRef] = []
    ) -> SessionFocusPreferences {
        SessionFocusPreferences(mode: mode, askOnNewSession: ask, pinned: pinned)
    }

    private func snapshot(status: SessionStatus, cacheRemaining: Int, usage: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .codex,
            connectionState: .connected,
            sessions: [AgentSession(
                id: "session-1",
                providerID: .codex,
                title: "Test session",
                status: status,
                lastActivityAt: .now,
                cache: CacheSnapshot(
                    temperature: cacheRemaining <= 60 ? .expiring : .warm,
                    remainingSeconds: cacheRemaining,
                    ttlSeconds: 300
                ),
                target: SessionTarget(providerID: .codex, sessionID: "session-1")
            )],
            usageWindows: [UsageWindow(id: "7d", label: "7 days", usedFraction: usage)]
        )
    }
}
