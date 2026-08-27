import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CodexConnectorTests: XCTestCase {
    func testReadsWorkingSessionCacheAndQuotaFromRollout() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appending(path: "2026/08/14/rollout-test.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)

        let contents = """
        {"timestamp":"1970-01-01T00:33:10.000Z","type":"session_meta","payload":{"id":"codex-1","cwd":"/tmp/AgentHearth","source":"cli","model_provider":"openai"}}
        {"timestamp":"1970-01-01T00:33:15.000Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"/tmp/AgentHearth","model":"gpt-5.6-sol"}}
        {"timestamp":"1970-01-01T00:33:18.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"1970-01-01T00:33:18.500Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10}}}}
        {"timestamp":"1970-01-01T00:33:19.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1000,"cache_write_input_tokens":0}},"rate_limits":{"primary":{"used_percent":27,"window_minutes":10080,"resets_at":4000}}}}
        """
        try Data(contents.utf8).write(to: rollout)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_999)], ofItemAtPath: rollout.path)

        let connector = CodexConnector(sessionsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].id, "codex-1")
        XCTAssertEqual(snapshot.sessions[0].status, .working)
        XCTAssertEqual(snapshot.sessions[0].model, "gpt-5.6-sol")
        XCTAssertEqual(snapshot.sessions[0].cache.cachedReadTokens, 1_000)
        // Codex input_tokens (1200) already includes the 1000 cached, so real
        // reuse is 1000/1200 = 0.833 — not 1000/(1200+1000) = 0.45.
        XCTAssertEqual(snapshot.sessions[0].cache.inputTokens, 200)
        XCTAssertEqual(try XCTUnwrap(snapshot.sessions[0].cache.cacheReuseRate), 0.8333, accuracy: 0.0005)
        XCTAssertEqual(snapshot.sessions[0].cache.ttlSeconds, 1_800)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.hitCount, 1)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.expectedColdStartCount, 1)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.hitRate, 0.5)
        XCTAssertEqual(snapshot.usageWindows.first?.label, "7 days")
        XCTAssertEqual(snapshot.usageWindows.first?.usedFraction, 0.27)
    }

    func testRealtimeOnlyUsesHookWithoutRollout() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = CodexConnector(sessionsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        try await connector.ingest(CodexHookEvent(
            eventName: "PermissionRequest",
            sessionID: "codex-live",
            workingDirectory: "/tmp/AgentHearth",
            model: "gpt-5.6-sol",
            sentAt: 1_999_000
        ))
        await connector.setSourceMode(.realtimeOnly)
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.first?.status, .waitingForApproval)
        XCTAssertEqual(snapshot.sessions.first?.cache, .unknown)
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testInterruptedAbortIsIdleRatherThanFailed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appending(path: "rollout-interrupted.jsonl")
        let contents = """
        {"timestamp":"1970-01-01T00:33:10.000Z","type":"session_meta","payload":{"id":"codex-interrupted","cwd":"/tmp/AgentHearth"}}
        {"timestamp":"1970-01-01T00:33:18.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}
        {"timestamp":"1970-01-01T00:33:19.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1000}}}}
        """
        try Data(contents.utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_999)],
            ofItemAtPath: rollout.path
        )

        let connector = CodexConnector(sessionsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
    }

    func testKeepsNewestObservationWhenRolloutFilesShareASessionID() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "rollout-first.jsonl")
        let latest = root.appending(path: "rollout-latest.jsonl")
        let earlierContents = """
        {"timestamp":"1970-01-01T00:33:10.000Z","type":"session_meta","payload":{"id":"codex-duplicate","cwd":"/tmp/AgentHearth"}}
        {"timestamp":"1970-01-01T00:33:18.000Z","type":"event_msg","payload":{"type":"task_started"}}
        """
        let laterContents = """
        {"timestamp":"1970-01-01T00:33:10.000Z","type":"session_meta","payload":{"id":"codex-duplicate","cwd":"/tmp/AgentHearth"}}
        {"timestamp":"1970-01-01T00:33:19.000Z","type":"event_msg","payload":{"type":"task_started"}}
        """
        try Data(earlierContents.utf8).write(to: first)
        try Data(laterContents.utf8).write(to: latest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_998)],
            ofItemAtPath: first.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_999)],
            ofItemAtPath: latest.path
        )

        let connector = CodexConnector(sessionsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.lastActivityAt, Date(timeIntervalSince1970: 1_999))
    }

    func testUnchangedRolloutIsDecodedOnlyOnceAcrossPolls() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appending(path: "rollout-cached.jsonl")
        try Data("""
        {"timestamp":"1970-01-01T00:33:10.000Z","type":"session_meta","payload":{"id":"codex-cached","cwd":"/tmp/AgentHearth"}}
        {"timestamp":"1970-01-01T00:33:19.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1000,"cache_write_input_tokens":0}}}}
        """.utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: rollout.path
        )

        let connector = CodexConnector(sessionsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let first = try await connector.snapshot()
        let second = try await connector.snapshot()

        let decodeCount = await connector.rolloutDecodeCount
        XCTAssertEqual(decodeCount, 1)
        XCTAssertEqual(second.sessions.map(\.id), first.sessions.map(\.id))
        XCTAssertEqual(second.sessions.first?.cache.cachedReadTokens, 1_000)
    }

    func testChangedRolloutInvalidatesTheCachedSummary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appending(path: "rollout-growing.jsonl")
        let firstLines = """
        {"timestamp":"1970-01-01T00:33:10.000Z","type":"session_meta","payload":{"id":"codex-growing","cwd":"/tmp/AgentHearth"}}
        {"timestamp":"1970-01-01T00:33:19.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":1000,"cache_write_input_tokens":0}}}}
        """
        try Data(firstLines.utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: rollout.path
        )

        let connector = CodexConnector(sessionsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        _ = try await connector.snapshot()

        try Data("""
        \(firstLines)
        {"timestamp":"1970-01-01T00:33:25.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2400,"cached_input_tokens":2000,"cache_write_input_tokens":0}}}}
        """.utf8).write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_500)],
            ofItemAtPath: rollout.path
        )
        let snapshot = try await connector.snapshot()

        let decodeCount = await connector.rolloutDecodeCount
        XCTAssertEqual(decodeCount, 2)
        XCTAssertEqual(snapshot.sessions.first?.cache.cachedReadTokens, 2_000)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AgentHearth-Codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
