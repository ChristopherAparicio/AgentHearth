import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class RemoteAgentClientTests: XCTestCase {
    func testQualifiesRemoteSessionAndPreservesResumeIdentifier() async throws {
        let payload = """
        {
          "schema_version": 1,
          "provider": "codex",
          "available": true,
          "message": null,
          "sessions": [{
            "id": "remote-session",
            "title": "Codex · sample-project",
            "project_name": "sample-project",
            "model": "gpt-5.6-sol",
            "status": "working",
            "last_activity_at": 2000000,
            "cache": {
              "temperature": "warm",
              "remaining_seconds": 1700,
              "ttl_seconds": 1800,
              "cached_read_tokens": 900,
              "cache_write_tokens": 0,
              "last_confirmed_at": 1999000,
              "confidence": "observed",
              "reason": "remote telemetry"
            },
            "cache_health": {
              "hit_count": 6,
              "avoidable_miss_count": 1,
              "expected_cold_start_count": 1,
              "unknown_count": 0,
              "measured_at": 2000000
            },
            "working_directory": "/home/me/dev/projects/sample-project"
          }],
          "usage_windows": [{
            "id": "codex-10080",
            "label": "7 days",
            "used_fraction": 0.45,
            "resets_at": 4000000,
            "measured_at": 2000000
          }],
          "updated_at": 2000000
        }
        """
        let configuration = RemoteHostConfiguration(
            id: "rtx",
            displayName: "RTX 5090",
            sshDestination: "rtx-server"
        )
        let client = RemoteAgentClient(
            configuration: configuration,
            runner: StubSSHRunner(output: Data(payload.utf8)),
            now: { Date(timeIntervalSince1970: 2_001) }
        )

        let snapshot = try await client.snapshot(for: .codex, sourceMode: .automatic)

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.first?.id, "rtx:codex:remote-session")
        XCTAssertEqual(snapshot.sessions.first?.host.displayName, "RTX 5090")
        XCTAssertEqual(snapshot.sessions.first?.target?.sessionID, "remote-session")
        XCTAssertEqual(snapshot.sessions.first?.target?.host.sshDestination, "rtx-server")
        XCTAssertEqual(snapshot.sessions.first?.cache.cachedReadTokens, 900)
        XCTAssertEqual(snapshot.usageWindows.first?.id, "rtx:codex-10080")
    }

    func testRejectsUnsafeSSHDestinationBeforeLaunching() async {
        let configuration = RemoteHostConfiguration(
            displayName: "Unsafe",
            sshDestination: "-oProxyCommand=bad"
        )
        let client = RemoteAgentClient(configuration: configuration)

        do {
            _ = try await client.health()
            XCTFail("Expected destination validation to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, SSHCommandError.invalidDestination.localizedDescription)
        }
    }

    func testScopesAnExplicitRemoteOpenCodeServer() async throws {
        let payload = """
        {
          "schema_version":1,"provider":"openCode","available":true,"message":null,
          "sessions":[{
            "id":"oc-1","title":"Remote OpenCode","project_name":"project","model":"gpt-5.6-sol",
            "status":"working","last_activity_at":2000000,
            "cache":{"temperature":"warm","remaining_seconds":1200,"ttl_seconds":1800,
              "cached_read_tokens":100,"cache_write_tokens":0,"last_confirmed_at":1999000,
              "confidence":"observed","reason":"server telemetry"},
            "cache_health":null,"working_directory":"/home/me/project"
          }],"usage_windows":[],"updated_at":2000000
        }
        """
        let host = RemoteHostConfiguration(
            id: "rtx",
            displayName: "RTX",
            sshDestination: "rtx-server"
        )
        let server = OpenCodeServerConfiguration(
            id: "rtx-opencode",
            displayName: "RTX OpenCode",
            hostID: host.id,
            port: 4096
        )
        let client = RemoteAgentClient(
            configuration: host,
            runner: StubSSHRunner(output: Data(payload.utf8))
        )

        let snapshot = try await client.openCodeServerSnapshot(server)

        XCTAssertEqual(snapshot.sessions.first?.source, server.source)
        XCTAssertEqual(snapshot.sessions.first?.id, "rtx:openCode:rtx-opencode:oc-1")
        XCTAssertEqual(snapshot.sessions.first?.target?.sessionID, "oc-1")
    }

    func testReplaysNormalizedRemoteHistoryWithAStableHostScopedID() async throws {
        let payload = """
        {
          "schema_version":1,"next_cursor":42,
          "events":[{
            "id":42,"provider":"codex","session_id":"remote-session",
            "title":"Codex · project","model":"gpt-test","occurred_at":2000000,
            "hit_count":1,"miss_count":0,"cold_start_count":0,"unknown_count":0,
            "current_hit_count":7,"current_miss_count":2,
            "current_cold_start_count":1,"current_unknown_count":0
          }]
        }
        """
        let configuration = RemoteHostConfiguration(
            id: "rtx",
            displayName: "RTX 5090",
            sshDestination: "rtx-server"
        )
        let client = RemoteAgentClient(
            configuration: configuration,
            runner: StubSSHRunner(output: Data(payload.utf8))
        )

        let events = try await client.pendingHistoryEvents(for: .codex)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.externalID, "remote:rtx:42")
        XCTAssertEqual(events.first?.sessionKey, "codex:rtx:remote-session")
        XCTAssertEqual(events.first?.currentHitCount, 7)
        XCTAssertEqual(events.first?.hostName, "RTX 5090")
    }

    func testSnapshotCacheIsScopedPerProvider() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 2_000))
        let runner = CountingSSHRunner()
        let client = RemoteAgentClient(
            configuration: RemoteHostConfiguration(
                id: "rtx",
                displayName: "RTX 5090",
                sshDestination: "rtx-server"
            ),
            runner: runner,
            now: { clock.value }
        )

        _ = try await client.snapshot(for: .codex, sourceMode: .automatic)
        clock.value = Date(timeIntervalSince1970: 2_002)
        _ = try await client.snapshot(for: .claudeCode, sourceMode: .automatic)
        XCTAssertEqual(runner.commandCount, 2)

        // Four seconds after the Codex fetch: fetching Claude Code two seconds
        // earlier must not have refreshed the Codex window.
        clock.value = Date(timeIntervalSince1970: 2_004)
        _ = try await client.snapshot(for: .codex, sourceMode: .automatic)
        XCTAssertEqual(runner.commandCount, 3)

        // Claude Code itself is still inside its own freshness window.
        _ = try await client.snapshot(for: .claudeCode, sourceMode: .automatic)
        XCTAssertEqual(runner.commandCount, 3)
    }

    /// An unreachable host must not be re-dialed on every poll: after a failure
    /// the client backs off exponentially and reports the last error meanwhile.
    func testBacksOffAfterAFailureAndRecoversOnSuccess() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let runner = FailingSSHRunner()
        let client = RemoteAgentClient(
            configuration: RemoteHostConfiguration(id: "rtx", displayName: "RTX", sshDestination: "rtx-server"),
            runner: runner,
            now: { clock.value }
        )

        await XCTAssertThrowsErrorAsync(try await client.snapshot(for: .codex, sourceMode: .automatic))
        XCTAssertEqual(runner.commandCount, 1)

        // Inside the first 10 s window: no ssh spawned, the last error is surfaced.
        clock.value = clock.value.addingTimeInterval(5)
        do {
            _ = try await client.snapshot(for: .claudeCode, sourceMode: .automatic)
            XCTFail("expected backoff error")
        } catch let error as RemoteAgentError {
            guard case let .backingOff(_, lastError) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(lastError.contains("connection refused"))
            XCTAssertTrue(error.localizedDescription.contains("retrying in"))
        }
        XCTAssertEqual(runner.commandCount, 1)

        // After the window a real attempt is made; a second failure doubles it.
        clock.value = clock.value.addingTimeInterval(6)
        await XCTAssertThrowsErrorAsync(try await client.snapshot(for: .codex, sourceMode: .automatic))
        XCTAssertEqual(runner.commandCount, 2)
        clock.value = clock.value.addingTimeInterval(15)
        await XCTAssertThrowsErrorAsync(try await client.snapshot(for: .codex, sourceMode: .automatic))
        XCTAssertEqual(runner.commandCount, 2, "still inside the doubled 20 s window")

        // An explicit health check bypasses the backoff and, on success, lifts it.
        runner.shouldFail = false
        _ = try await client.health()
        XCTAssertEqual(runner.commandCount, 3)
        _ = try await client.snapshot(for: .codex, sourceMode: .automatic)
        XCTAssertEqual(runner.commandCount, 4)
    }

    /// The three provider connectors of one host fail together on an outage;
    /// that single outage must count as one failure, not escalate three times.
    func testConcurrentFailuresCountAsOneBackoffStep() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let runner = FailingSSHRunner()
        let client = RemoteAgentClient(
            configuration: RemoteHostConfiguration(id: "rtx", displayName: "RTX", sshDestination: "rtx-server"),
            runner: runner,
            now: { clock.value }
        )

        async let first: Void = XCTAssertThrowsErrorAsync(try await client.snapshot(for: .codex, sourceMode: .automatic))
        async let second: Void = XCTAssertThrowsErrorAsync(try await client.snapshot(for: .claudeCode, sourceMode: .automatic))
        async let third: Void = XCTAssertThrowsErrorAsync(try await client.snapshot(for: .openCode, sourceMode: .automatic))
        _ = await (first, second, third)
        XCTAssertEqual(runner.commandCount, 3)

        // One step (10 s), not three (40 s): 15 s later the host is dialed again.
        clock.value = clock.value.addingTimeInterval(15)
        await XCTAssertThrowsErrorAsync(try await client.snapshot(for: .codex, sourceMode: .automatic))
        XCTAssertEqual(runner.commandCount, 4)
    }

    func testBackoffIsCappedAtTheMaximum() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let runner = FailingSSHRunner()
        let client = RemoteAgentClient(
            configuration: RemoteHostConfiguration(id: "rtx", displayName: "RTX", sshDestination: "rtx-server"),
            runner: runner,
            now: { clock.value }
        )
        for _ in 0..<12 {
            await XCTAssertThrowsErrorAsync(try await client.snapshot(for: .codex, sourceMode: .automatic))
            clock.value = clock.value.addingTimeInterval(RemoteAgentClient.maximumBackoff + 1)
        }
        XCTAssertEqual(runner.commandCount, 12, "the cap keeps every attempt at most maximumBackoff apart")
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

private final class FailingSSHRunner: SSHCommandRunning, @unchecked Sendable {
    private(set) var commandCount = 0
    var shouldFail = true

    func run(
        destination: String,
        remoteCommand: String,
        standardInput: Data?
    ) async throws -> SSHCommandResult {
        commandCount += 1
        if shouldFail {
            throw SSHCommandError.commandFailed(destination: destination, message: "ssh: connection refused")
        }
        let payload = remoteCommand.contains(" health")
            ? #"{"schema_version":1,"service":"AgentHearth Remote","status":"ok","version":"0.2.0"}"#
            : #"{"schema_version":1,"provider":"codex","available":true,"message":null,"sessions":[],"usage_windows":[],"updated_at":2000000}"#
        return SSHCommandResult(standardOutput: Data(payload.utf8), standardError: "", exitCode: 0)
    }
}

private final class MutableClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) { self.value = value }
}

private final class CountingSSHRunner: SSHCommandRunning, @unchecked Sendable {
    private(set) var commandCount = 0

    func run(
        destination: String,
        remoteCommand: String,
        standardInput: Data?
    ) async throws -> SSHCommandResult {
        commandCount += 1
        let provider = remoteCommand.contains("claude-code") ? "claudeCode" : "codex"
        let payload = """
        {"schema_version":1,"provider":"\(provider)","available":true,"message":null,
         "sessions":[],"usage_windows":[],"updated_at":2000000}
        """
        return SSHCommandResult(standardOutput: Data(payload.utf8), standardError: "", exitCode: 0)
    }
}

private struct StubSSHRunner: SSHCommandRunning {
    let output: Data

    func run(
        destination: String,
        remoteCommand: String,
        standardInput: Data?
    ) async throws -> SSHCommandResult {
        SSHCommandResult(standardOutput: output, standardError: "", exitCode: 0)
    }
}
