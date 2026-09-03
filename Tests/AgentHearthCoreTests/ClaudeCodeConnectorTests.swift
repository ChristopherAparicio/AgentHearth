import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class ClaudeCodeConnectorTests: XCTestCase {
    func testCombinesTranscriptCacheWithLivePermissionState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "project/claude-1.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)

        let contents = """
        {"type":"user","timestamp":"1970-01-01T00:33:10.000Z","sessionId":"claude-1","cwd":"/tmp/AgentHearth","message":{"role":"user","content":"ignored by decoder"}}
        {"type":"ai-title","sessionId":"claude-1","aiTitle":"AgentHearth cache monitor"}
        {"type":"assistant","timestamp":"1970-01-01T00:33:19.000Z","sessionId":"claude-1","requestId":"request-1","cwd":"/tmp/AgentHearth","message":{"id":"message-1","role":"assistant","model":"claude-sonnet-4-6","content":"ignored by decoder","usage":{"input_tokens":10,"cache_creation_input_tokens":500,"cache_read_input_tokens":9000,"cache_creation":{"ephemeral_1h_input_tokens":500,"ephemeral_5m_input_tokens":0}}}}
        {"type":"assistant","timestamp":"1970-01-01T00:33:19.500Z","sessionId":"claude-1","requestId":"request-1","cwd":"/tmp/AgentHearth","message":{"id":"message-1","role":"assistant","model":"claude-sonnet-4-6","content":"duplicate ignored by decoder","usage":{"input_tokens":10,"cache_creation_input_tokens":500,"cache_read_input_tokens":9000,"cache_creation":{"ephemeral_1h_input_tokens":500,"ephemeral_5m_input_tokens":0}}}}
        """
        try Data(contents.utf8).write(to: transcript)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_999)], ofItemAtPath: transcript.path)

        let connector = ClaudeCodeConnector(projectsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        try await connector.ingest(ClaudeCodeHookEvent(
            eventName: "PermissionRequest",
            sessionID: "claude-1",
            transcriptPath: transcript.path,
            workingDirectory: "/tmp/AgentHearth",
            model: "claude-sonnet-4-6",
            sentAt: 1_999_500
        ))
        try await connector.ingest(ClaudeCodeStatusEvent(
            sessionID: "claude-1",
            workingDirectory: "/tmp/AgentHearth",
            model: "claude-sonnet-4-6",
            fiveHour: ClaudeCodeRateLimitWindow(usedPercentage: 42, resetsAt: 3_000),
            sevenDay: ClaudeCodeRateLimitWindow(usedPercentage: 73, resetsAt: 4_000),
            sentAt: 1_999_600
        ))
        try await connector.ingest(ClaudeCodeStatusEvent(
            sessionID: "new-session-without-rate-limits",
            sentAt: 1_999_700
        ))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].title, "AgentHearth cache monitor")
        XCTAssertEqual(snapshot.sessions[0].status, .waitingForApproval)
        XCTAssertEqual(snapshot.sessions[0].cache.ttlSeconds, 3_600)
        XCTAssertEqual(snapshot.sessions[0].cache.cachedReadTokens, 9_000)
        // 9000 read / (10 fresh + 9000 read + 500 written) = 0.9464, not 100%.
        XCTAssertEqual(try XCTUnwrap(snapshot.sessions[0].cache.cacheReuseRate), 0.9464, accuracy: 0.0005)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.hitCount, 1)
        XCTAssertEqual(snapshot.usageWindows.map(\.label), ["5 hours", "7 days"])
        XCTAssertEqual(snapshot.usageWindows.map(\.usedFraction), [0.42, 0.73])
    }

    func testLocalOnlyIgnoresHookStateAndRateLimits() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "claude-local.jsonl")
        try Data("""
        {"type":"assistant","timestamp":"1970-01-01T00:33:19.000Z","sessionId":"claude-local","cwd":"/tmp/AgentHearth","message":{"id":"message-local","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"cache_read_input_tokens":100}}}
        """.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_999)],
            ofItemAtPath: transcript.path
        )

        let connector = ClaudeCodeConnector(projectsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        try await connector.ingest(ClaudeCodeHookEvent(
            eventName: "PermissionRequest",
            sessionID: "claude-local",
            sentAt: 1_999_500
        ))
        try await connector.ingest(ClaudeCodeStatusEvent(
            sessionID: "claude-local",
            fiveHour: ClaudeCodeRateLimitWindow(usedPercentage: 50),
            sentAt: 1_999_600
        ))
        await connector.setSourceMode(.localOnly)
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testOldUnansweredTranscriptReturnsToIdleWithoutAFreshHook() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "stale.jsonl")
        try Data("""
        {"type":"user","timestamp":"1970-01-01T00:01:00.000Z","sessionId":"stale","cwd":"/tmp/AgentHearth","message":{"role":"user","content":"Ignored fixture content"}}
        """.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_999)],
            ofItemAtPath: transcript.path
        )

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            hookFreshness: 60,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
    }

    func testAssistantReplyWithoutUsageDoesNotMarkSessionAsStuck() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "replied.jsonl")
        try Data("""
        {"type":"user","timestamp":"1970-01-01T00:31:00.000Z","sessionId":"replied","cwd":"/tmp/AgentHearth"}
        {"type":"assistant","timestamp":"1970-01-01T00:31:10.000Z","sessionId":"replied","message":{"role":"assistant","content":"No usage metadata"}}
        """.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_999)],
            ofItemAtPath: transcript.path
        )

        let connector = ClaudeCodeConnector(projectsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
    }

    func testUnchangedTranscriptIsDecodedOnlyOnceAcrossPolls() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "cached.jsonl")
        try Data("""
        {"type":"assistant","timestamp":"1970-01-01T00:33:19.000Z","sessionId":"cached","cwd":"/tmp/AgentHearth","message":{"id":"message-1","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"cache_read_input_tokens":100}}}
        """.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: transcript.path
        )

        let connector = ClaudeCodeConnector(projectsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let first = try await connector.snapshot()
        let second = try await connector.snapshot()

        let decodeCount = await connector.transcriptDecodeCount
        XCTAssertEqual(decodeCount, 1)
        XCTAssertEqual(second.sessions.map(\.id), first.sessions.map(\.id))
        XCTAssertEqual(second.sessions.first?.cache.cachedReadTokens, 100)
    }

    func testChangedTranscriptInvalidatesTheCachedSummary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "growing.jsonl")
        let firstLine = """
        {"type":"assistant","timestamp":"1970-01-01T00:33:19.000Z","sessionId":"growing","cwd":"/tmp/AgentHearth","message":{"id":"message-1","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"cache_read_input_tokens":100}}}
        """
        try Data(firstLine.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: transcript.path
        )

        let connector = ClaudeCodeConnector(projectsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        _ = try await connector.snapshot()

        try Data("""
        \(firstLine)
        {"type":"ai-title","sessionId":"growing","aiTitle":"Fresh transcript title"}
        """.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_500)],
            ofItemAtPath: transcript.path
        )
        let snapshot = try await connector.snapshot()

        let decodeCount = await connector.transcriptDecodeCount
        XCTAssertEqual(decodeCount, 2)
        XCTAssertEqual(snapshot.sessions.first?.title, "Fresh transcript title")
    }

    func testReadsFiveHourAndSevenDayUsageFromDesktopJournalWithoutASession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        try Data("""
        {"version":2,"samples":[
        {"t":1000000,"org":"org-1","u":{"fh":5,"sd":20}},
        {"t":1900000,"org":"org-1","u":{"fh":18,"sd":49}}
        ]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.usageWindows.map(\.label), ["5 hours", "7 days"])
        XCTAssertEqual(snapshot.usageWindows.map(\.usedFraction), [0.18, 0.49])
        XCTAssertEqual(snapshot.usageWindows.first?.measuredAt, Date(timeIntervalSince1970: 1_900))
    }

    func testDesktopJournalUsageBorrowsResetTimesFromTheRelay() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        // Journal sample (t=1_900s) is newer than the relay event (t=1_500s),
        // so its percentages win — but the journal has no reset time.
        try Data("""
        {"version":2,"samples":[{"t":1900000,"org":"org-1","u":{"fh":18,"sd":49}}]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        try await connector.ingest(ClaudeCodeStatusEvent(
            sessionID: "live",
            fiveHour: ClaudeCodeRateLimitWindow(usedPercentage: 10, resetsAt: 3_000),
            sevenDay: ClaudeCodeRateLimitWindow(usedPercentage: 10, resetsAt: 4_000),
            sentAt: 1_500_000
        ))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.usageWindows.map(\.usedFraction), [0.18, 0.49])
        XCTAssertEqual(snapshot.usageWindows.first?.resetsAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(snapshot.usageWindows.last?.resetsAt, Date(timeIntervalSince1970: 4_000))
    }

    func testStatusLineRelayWinsOverAnOlderDesktopJournalSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        try Data("""
        {"version":2,"samples":[{"t":1000000,"org":"org-1","u":{"fh":10,"sd":10}}]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        try await connector.ingest(ClaudeCodeStatusEvent(
            sessionID: "live",
            fiveHour: ClaudeCodeRateLimitWindow(usedPercentage: 42, resetsAt: 3_000),
            sevenDay: ClaudeCodeRateLimitWindow(usedPercentage: 73, resetsAt: 4_000),
            sentAt: 1_500_000
        ))
        let snapshot = try await connector.snapshot()

        // Relay sample (t=1_500s) is newer than the journal sample (t=1_000s).
        XCTAssertEqual(snapshot.usageWindows.map(\.usedFraction), [0.42, 0.73])
        XCTAssertEqual(snapshot.usageWindows.first?.resetsAt, Date(timeIntervalSince1970: 3_000))
    }

    func testStaleDesktopJournalIsIgnored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        // Sample measured well beyond the 7-day relevance window.
        try Data("""
        {"version":2,"samples":[{"t":1000,"org":"org-1","u":{"fh":18,"sd":49}}]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        let snapshot = try await connector.snapshot()

        XCTAssertTrue(snapshot.usageWindows.isEmpty)
    }

    func testAccountUsageSuppliesResetWhileJournalKeepsTheFresherPercent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        // Journal is the freshest source for the percentage (t=1900s) but has no
        // reset; account usage (fetched at 1800s) carries the reset timestamps.
        try Data("""
        {"version":2,"samples":[{"t":1900000,"org":"org-1","u":{"fh":26,"sd":17}}]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        await connector.ingestAccountUsage(AccountUsage(
            fiveHour: .init(utilizationFraction: 0.25, resetsAt: Date(timeIntervalSince1970: 5_000)),
            sevenDay: .init(utilizationFraction: 0.16, resetsAt: Date(timeIntervalSince1970: 9_000)),
            fetchedAt: Date(timeIntervalSince1970: 1_800)
        ))
        let snapshot = try await connector.snapshot()

        // Percent from the fresher journal, reset from the authoritative account.
        XCTAssertEqual(snapshot.usageWindows.map(\.usedFraction), [0.26, 0.17])
        XCTAssertEqual(snapshot.usageWindows.first?.resetsAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(snapshot.usageWindows.last?.resetsAt, Date(timeIntervalSince1970: 9_000))
    }

    /// Per-model weekly limits from the account endpoint become extra windows
    /// after the two global ones, with a stable id the menu bar can pin.
    func testScopedWeeklyLimitsFollowTheGlobalWindows() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: root.appending(path: "missing.json"),
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        await connector.ingestAccountUsage(AccountUsage(
            fiveHour: .init(utilizationFraction: 0.25, resetsAt: Date(timeIntervalSince1970: 5_000)),
            sevenDay: .init(utilizationFraction: 0.35, resetsAt: Date(timeIntervalSince1970: 9_000)),
            scopedWeekly: [
                .init(id: "fable", label: "Fable", window: .init(utilizationFraction: 0.56, resetsAt: Date(timeIntervalSince1970: 9_100)), isActive: true),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_800)
        ))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.usageWindows.map(\.id), ["claude-5h", "claude-7d", "claude-7d-fable"])
        XCTAssertEqual(snapshot.usageWindows.last?.label, "Fable")
        XCTAssertEqual(snapshot.usageWindows.last?.usedFraction ?? 0, 0.56, accuracy: 0.0001)
        XCTAssertEqual(snapshot.usageWindows.last?.resetsAt, Date(timeIntervalSince1970: 9_100))

        // The user preference strips them before ingestion.
        await connector.ingestAccountUsage(AccountUsage(
            fiveHour: .init(utilizationFraction: 0.25, resetsAt: nil),
            sevenDay: .init(utilizationFraction: 0.35, resetsAt: nil),
            scopedWeekly: [.init(id: "fable", label: "Fable", window: .init(utilizationFraction: 0.56, resetsAt: nil), isActive: true)],
            fetchedAt: Date(timeIntervalSince1970: 1_800)
        ).withoutScopedWeekly())
        let stripped = try await connector.snapshot()
        XCTAssertEqual(stripped.usageWindows.map(\.id), ["claude-5h", "claude-7d"])
    }

    func testStaleAccountUsageIsIgnored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        try Data("""
        {"version":2,"samples":[{"t":1900000,"org":"org-1","u":{"fh":26,"sd":17}}]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )
        await connector.ingestAccountUsage(AccountUsage(
            fiveHour: .init(utilizationFraction: 0.25, resetsAt: Date(timeIntervalSince1970: 5_000)),
            sevenDay: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        ))
        let snapshot = try await connector.snapshot()

        // Account fetch is far older than the relevance window, so no reset leaks.
        XCTAssertNil(snapshot.usageWindows.first?.resetsAt)
    }

    func testUnchangedDesktopJournalIsDecodedOnlyOnceAcrossPolls() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appending(path: "plan-usage-history.json")
        try Data("""
        {"version":2,"samples":[{"t":1900000,"org":"org-1","u":{"fh":18,"sd":49}}]}
        """.utf8).write(to: journal)

        let connector = ClaudeCodeConnector(
            projectsURL: root,
            planUsageHistoryURL: journal,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        _ = try await connector.snapshot()
        _ = try await connector.snapshot()

        let decodeCount = await connector.planUsageDecodeCount
        XCTAssertEqual(decodeCount, 1)
    }

    func testSessionReuseAggregatesAllTurnsNotJustTheLast() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appending(path: "mixed.jsonl")
        // Turn 1 is a cold start (no read, big creation); turn 2 is a warm hit.
        // Aggregate reuse must reflect BOTH, not just the last (warm) turn.
        try Data("""
        {"type":"assistant","timestamp":"1970-01-01T00:33:10.000Z","sessionId":"mixed","cwd":"/tmp/AgentHearth","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":900}}}
        {"type":"assistant","timestamp":"1970-01-01T00:33:19.000Z","sessionId":"mixed","cwd":"/tmp/AgentHearth","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":2,"cache_read_input_tokens":998,"cache_creation_input_tokens":0}}}
        """.utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_999)],
            ofItemAtPath: transcript.path
        )

        let connector = ClaudeCodeConnector(projectsURL: root, now: { Date(timeIntervalSince1970: 2_000) })
        let snapshot = try await connector.snapshot()

        // Last turn alone would read 998/1000 = 99.8%; the session aggregate is
        // 998 read / (100+900 + 2+998) = 998/2000 = 49.9%.
        XCTAssertEqual(snapshot.sessions[0].cache.cacheReuseRate ?? 0, 0.998, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(snapshot.sessions[0].cacheHealth?.tokenReuseRate), 0.499, accuracy: 0.002)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AgentHearth-Claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
