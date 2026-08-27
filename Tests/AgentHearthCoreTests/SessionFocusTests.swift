import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class SessionFocusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRefMatchingIsHostScoped() {
        let local = session("session-1", status: .working)
        let remote = session("session-1", status: .working, host: remoteHost)
        let ref = PrioritySessionRef(session: local)

        XCTAssertTrue(ref.matches(local))
        XCTAssertFalse(ref.matches(remote))
        XCTAssertFalse(ref.matches(session("session-2", status: .working)))
        XCTAssertFalse(
            PrioritySessionRef(providerID: .claudeCode, hostID: AgentHost.local.id, sessionID: "session-1")
                .matches(local)
        )
    }

    func testRefFromTargetMatchesTheSameSession() {
        let observed = session("session-1", status: .working, host: remoteHost)
        let target = SessionTarget(providerID: .codex, sessionID: "session-1", host: remoteHost)

        XCTAssertTrue(PrioritySessionRef(target: target).matches(observed))
    }

    func testPinUnpinAndTogglePin() {
        var preferences = SessionFocusPreferences()
        let live = session("session-1", status: .working)

        preferences.pin(live, now: now)
        XCTAssertTrue(preferences.isPinned(live))
        XCTAssertEqual(preferences.lastSeenAt[PrioritySessionRef(session: live).key], now)

        // Pinning again does not duplicate the ref.
        preferences.pin(live, now: now)
        XCTAssertEqual(preferences.pinned.count, 1)

        preferences.togglePin(live)
        XCTAssertFalse(preferences.isPinned(live))
        XCTAssertTrue(preferences.lastSeenAt.isEmpty)
    }

    func testReconcileUnpinsCompletedAndFailedSessions() {
        var preferences = SessionFocusPreferences()
        let completed = session("session-1", status: .working)
        let failed = session("session-2", status: .working)
        let active = session("session-3", status: .working)
        preferences.pin(completed, now: now)
        preferences.pin(failed, now: now)
        preferences.pin(active, now: now)

        let changed = preferences.reconcile(
            sessions: [
                session("session-1", status: .completed),
                session("session-2", status: .failed),
                active,
            ],
            now: now.addingTimeInterval(60)
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(preferences.pinned.map(\.sessionID), ["session-3"])
        XCTAssertEqual(Array(preferences.lastSeenAt.keys), [PrioritySessionRef(session: active).key])
    }

    func testReconcilePrunesRefsUnseenForSevenDays() {
        var preferences = SessionFocusPreferences()
        let vanished = session("session-1", status: .working)
        preferences.pin(vanished, now: now)

        let sixDays = now.addingTimeInterval(6 * 24 * 60 * 60)
        XCTAssertFalse(preferences.reconcile(sessions: [], now: sixDays))
        XCTAssertEqual(preferences.pinned.count, 1)

        let sevenDays = now.addingTimeInterval(7 * 24 * 60 * 60)
        XCTAssertTrue(preferences.reconcile(sessions: [], now: sevenDays))
        XCTAssertTrue(preferences.pinned.isEmpty)
        XCTAssertTrue(preferences.lastSeenAt.isEmpty)
    }

    func testReconcileRefreshesLastSeenForLiveSessions() {
        var preferences = SessionFocusPreferences()
        let live = session("session-1", status: .working)
        preferences.pin(live, now: now)

        let later = now.addingTimeInterval(120)
        XCTAssertTrue(preferences.reconcile(sessions: [live], now: later))
        XCTAssertEqual(preferences.lastSeenAt[PrioritySessionRef(session: live).key], later)

        // Reconciling again at the same instant changes nothing.
        XCTAssertFalse(preferences.reconcile(sessions: [live], now: later))
    }

    func testReconcileWithoutPinsReturnsFalse() {
        var preferences = SessionFocusPreferences()
        XCTAssertFalse(preferences.reconcile(sessions: [session("session-1", status: .working)], now: now))
        XCTAssertEqual(preferences, SessionFocusPreferences())
    }

    func testDecodingEmptyObjectFallsBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(SessionFocusPreferences.self, from: Data("{}".utf8))

        XCTAssertEqual(decoded.mode, .all)
        XCTAssertTrue(decoded.askOnNewSession)
        XCTAssertTrue(decoded.pinned.isEmpty)
        XCTAssertTrue(decoded.lastSeenAt.isEmpty)
    }

    func testCodableRoundTripPreservesEveryField() throws {
        var preferences = SessionFocusPreferences(mode: .priorityOnly, askOnNewSession: false)
        preferences.pin(session("session-1", status: .working, host: remoteHost), now: now)

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(SessionFocusPreferences.self, from: data)

        XCTAssertEqual(decoded, preferences)
    }

    private var remoteHost: AgentHost {
        AgentHost(id: "remote-1", displayName: "Build Server", kind: .ssh, sshDestination: "build")
    }

    private func session(
        _ id: String,
        status: SessionStatus,
        host: AgentHost = .local
    ) -> AgentSession {
        AgentSession(
            id: id,
            providerID: .codex,
            title: "Session \(id)",
            status: status,
            lastActivityAt: now,
            host: host
        )
    }
}
