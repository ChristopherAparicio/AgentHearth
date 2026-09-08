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

    /// Regression: the warning was gated on `.expiring`, which connectors only
    /// set in the last 60 s, so a 5-minute lead time could never fire — the
    /// countdown crossed 300 s while the cache was still `.warm`.
    func testCacheWarningFiresForLeadTimesAboveOneMinute() async {
        let detector = SnapshotAlertDetector()
        var preferences = AlertPreferences()
        preferences.cacheWarningSeconds = 300

        _ = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 320, usage: 0.1)], preferences: preferences)
        let crossing = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 290, usage: 0.1)], preferences: preferences)
        XCTAssertEqual(crossing.map(\.type), ["cache.expiring"])
        XCTAssertTrue(crossing.first?.summary.contains("4:50") == true)

        // Still inside the window on the next poll: no repeat.
        let inside = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 250, usage: 0.1)], preferences: preferences)
        XCTAssertTrue(inside.isEmpty)

        // A renewed cache leaves the window and re-arms the warning.
        _ = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 1_800, usage: 0.1)], preferences: preferences)
        let again = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 299, usage: 0.1)], preferences: preferences)
        XCTAssertEqual(again.map(\.type), ["cache.expiring"])
    }

    func testDefaultOneMinuteWarningStillFiresOnce() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 90, usage: 0.1)], preferences: AlertPreferences())
        let alerts = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 59, usage: 0.1)], preferences: AlertPreferences())
        XCTAssertEqual(alerts.map(\.type), ["cache.expiring"])
        let repeated = await detector.detect(in: [snapshot(status: .idle, cacheRemaining: 30, usage: 0.1)], preferences: AlertPreferences())
        XCTAssertTrue(repeated.isEmpty)
    }

    /// Regression: a transient connector failure emptied the provider's
    /// sessions for one cycle, and the detector forgot them. On recovery every
    /// session looked brand new: transitions during the gap were lost and a
    /// cache already inside the warning window alerted a second time.
    func testRemembersSessionsAcrossATransientConnectorFailure() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [snapshot(status: .working, cacheRemaining: 45, usage: 0.1)], preferences: AlertPreferences())

        let degraded = ProviderSnapshot(
            id: .codex,
            connectionState: .degraded(message: "ssh: connect timed out"),
            sessions: [],
            usageWindows: []
        )
        let duringOutage = await detector.detect(in: [degraded], preferences: AlertPreferences())
        XCTAssertTrue(duringOutage.isEmpty)

        let recovered = await detector.detect(
            in: [snapshot(status: .waitingForApproval, cacheRemaining: 40, usage: 0.1)],
            preferences: AlertPreferences()
        )
        XCTAssertEqual(recovered.map(\.type), ["session.waitingForApproval"], "approval alert kept, cache alert not repeated")
    }

    func testForgetsDisappearedSessionsAfterTheRetentionWindow() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let detector = SnapshotAlertDetector(now: { clock.value })
        _ = await detector.detect(in: [snapshot(status: .working, cacheRemaining: 45, usage: 0.1)], preferences: AlertPreferences())
        _ = await detector.detect(in: [], preferences: AlertPreferences())

        clock.value = Date(timeIntervalSince1970: 1_000 + SnapshotAlertDetector.disappearedSessionRetention + 1)
        _ = await detector.detect(in: [], preferences: AlertPreferences())
        // Past the retention window the session is new again: the initial cache alert applies.
        let alerts = await detector.detect(in: [snapshot(status: .working, cacheRemaining: 45, usage: 0.1)], preferences: AlertPreferences())
        XCTAssertEqual(alerts.map(\.type), ["cache.expiring"])
    }

    // MARK: - Usage burn

    func testReportsABurstOnceRatherThanEveryPoll() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [burnSnapshot(usage: 0.20, minutes: 0)], preferences: AlertPreferences())

        let burst = await detector.detect(in: [burnSnapshot(usage: 0.42, minutes: 4)], preferences: AlertPreferences())
        XCTAssertEqual(burst.filter { $0.type == "usage.burn" }.count, 1)

        // Still climbing, but not by another full threshold: the same burst
        // must not alert again.
        let continued = await detector.detect(in: [burnSnapshot(usage: 0.47, minutes: 7)], preferences: AlertPreferences())
        XCTAssertTrue(continued.allSatisfy { $0.type != "usage.burn" })

        // A fresh rise of the configured size alerts again.
        let second = await detector.detect(in: [burnSnapshot(usage: 0.65, minutes: 10)], preferences: AlertPreferences())
        XCTAssertEqual(second.filter { $0.type == "usage.burn" }.count, 1)
    }

    func testDoesNotReportASteadyClimb() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [burnSnapshot(usage: 0.20, minutes: 0)], preferences: AlertPreferences())
        let alerts = await detector.detect(in: [burnSnapshot(usage: 0.28, minutes: 6)], preferences: AlertPreferences())

        XCTAssertTrue(alerts.allSatisfy { $0.type != "usage.burn" })
    }

    func testBurstNamesTheCostliestActiveSessionAndTargetsIt() async throws {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [burnSnapshot(usage: 0.20, minutes: 0)], preferences: AlertPreferences())

        let alerts = await detector.detect(
            in: [burnSnapshot(
                usage: 0.45,
                minutes: 5,
                sessions: [
                    burnSession(id: "quiet", project: "docs", uncachedInput: 800, output: 200),
                    burnSession(id: "runaway", project: "api-rewrite", uncachedInput: 90_000, output: 6_000)
                ]
            )],
            preferences: AlertPreferences()
        )

        let burn = try XCTUnwrap(alerts.first { $0.type == "usage.burn" })
        XCTAssertEqual(burn.sessionTarget?.sessionID, "runaway")
        XCTAssertTrue(burn.summary.contains("api-rewrite"), burn.summary)
        XCTAssertTrue(burn.summary.contains("+25 pts"), burn.summary)
    }

    func testBurstReportsHowLongTheSuspectHasBeenWorking() async {
        let clock = MutableClock(burnEpoch)
        let detector = SnapshotAlertDetector(now: { clock.value })
        let session = burnSession(id: "runaway", project: "api-rewrite", uncachedInput: 90_000, output: 6_000)
        _ = await detector.detect(in: [burnSnapshot(usage: 0.20, minutes: 0, sessions: [session])], preferences: AlertPreferences())

        clock.value = burnEpoch.addingTimeInterval(8 * 60)
        let alerts = await detector.detect(
            in: [burnSnapshot(usage: 0.45, minutes: 8, sessions: [session])],
            preferences: AlertPreferences()
        )

        let burn = alerts.first { $0.type == "usage.burn" }
        XCTAssertEqual(burn?.summary.contains("working 8 min"), true)
    }

    func testDisabledBurnRuleDoesNotReplayOnceReenabled() async {
        var disabled = AlertPreferences()
        disabled.usageBurnEnabled = false
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [burnSnapshot(usage: 0.20, minutes: 0)], preferences: disabled)
        _ = await detector.detect(in: [burnSnapshot(usage: 0.50, minutes: 4)], preferences: disabled)

        let alerts = await detector.detect(in: [burnSnapshot(usage: 0.52, minutes: 8)], preferences: AlertPreferences())
        XCTAssertTrue(alerts.allSatisfy { $0.type != "usage.burn" }, "the burst happened while the rule was off")
    }

    func testWindowRolloverIsNotABurst() async {
        let detector = SnapshotAlertDetector()
        _ = await detector.detect(in: [burnSnapshot(usage: 0.95, minutes: 0)], preferences: AlertPreferences())
        let alerts = await detector.detect(in: [burnSnapshot(usage: 0.02, minutes: 4)], preferences: AlertPreferences())

        XCTAssertTrue(alerts.allSatisfy { $0.type != "usage.burn" })
    }

    private var burnEpoch: Date { Date(timeIntervalSince1970: 2_000_000) }

    private func burnSession(
        id: String,
        project: String,
        uncachedInput: Int,
        output: Int
    ) -> AgentSession {
        AgentSession(
            id: id,
            providerID: .claudeCode,
            title: "Session \(id)",
            projectName: project,
            status: .working,
            lastActivityAt: burnEpoch,
            cache: CacheSnapshot(
                temperature: .warm,
                remainingSeconds: 240,
                ttlSeconds: 300,
                inputTokens: uncachedInput,
                outputTokens: output,
                cachedReadTokens: 500_000
            ),
            target: SessionTarget(providerID: .claudeCode, sessionID: id)
        )
    }

    /// A Claude 5h window read `minutes` after the epoch. Usage windows carry
    /// the provider's own measurement instant, which is what the burn rule
    /// measures elapsed time against.
    private func burnSnapshot(
        usage: Double,
        minutes: Double,
        sessions: [AgentSession] = []
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .claudeCode,
            connectionState: .connected,
            sessions: sessions,
            usageWindows: [UsageWindow(
                id: "claude-5h",
                label: "5 hours",
                usedFraction: usage,
                measuredAt: burnEpoch.addingTimeInterval(minutes * 60)
            )]
        )
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

    private final class MutableClock: @unchecked Sendable {
        var value: Date
        init(_ value: Date) { self.value = value }
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
