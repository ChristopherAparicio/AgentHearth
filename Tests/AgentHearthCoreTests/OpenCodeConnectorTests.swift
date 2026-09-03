import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class OpenCodeConnectorTests: XCTestCase {
    func testNormalizesLiveSessionAndCacheHealth() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let connector = OpenCodeConnector(databaseURL: missingDatabaseURL(), now: { now })
        let report = OpenCodeSessionReport(
            id: "session-1",
            title: "Build AgentHearth",
            projectPath: "/tmp/AgentHearth",
            model: "gpt-5",
            provider: "openai",
            status: .working,
            lastActivityAt: 1_999_000,
            cache: OpenCodeCacheReport(
                temperature: .warm,
                remainingSeconds: 240,
                ttlSeconds: 300,
                cachedReadTokens: 9_000,
                cacheWriteTokens: 1_000,
                hitCount: 8,
                avoidableMissCount: 2,
                expectedColdStartCount: 3
            )
        )

        try await connector.ingest(payload(sentAt: 1_999_000, sessions: [report]))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].projectName, "AgentHearth")
        XCTAssertEqual(snapshot.sessions[0].status, .working)
        XCTAssertEqual(snapshot.sessions[0].cache.cachedReadTokens, 9_000)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.hitRate, 8.0 / 13.0)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.band(), .mixed)
    }

    func testHidesColdIdleSessionsButKeepsConnectorConnected() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let connector = OpenCodeConnector(databaseURL: missingDatabaseURL(), now: { now })
        let report = OpenCodeSessionReport(
            id: "session-idle",
            title: "Old work",
            projectPath: "/tmp/project",
            status: .idle,
            lastActivityAt: 1_990_000,
            cache: OpenCodeCacheReport(temperature: .cold)
        )

        try await connector.ingest(payload(sentAt: 1_999_000, sessions: [report]))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testStalePayloadMakesProviderUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let connector = OpenCodeConnector(
            staleAfter: 75,
            databaseURL: missingDatabaseURL(),
            now: { now }
        )

        try await connector.ingest(payload(sentAt: 1_900_000, sessions: []))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .unavailable)
    }

    func testRejectsUnsupportedSchema() async {
        let connector = OpenCodeConnector(databaseURL: missingDatabaseURL())
        let unsupported = OpenCodePushPayload(
            schemaVersion: 99,
            pluginVersion: "test",
            instance: "/tmp/project",
            sentAt: 1,
            sessions: []
        )

        do {
            try await connector.ingest(unsupported)
            XCTFail("Expected unsupported schema error")
        } catch {
            XCTAssertEqual(error as? OpenCodePayloadError, .unsupportedSchema(99))
        }
    }

    func testLocalOnlyReadsRecentSessionAndCacheFromSQLite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-OpenCode-SQLite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "opencode.db")
        try createOpenCodeDatabase(at: database)

        let connector = OpenCodeConnector(
            databaseURL: database,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        await connector.setSourceMode(.localOnly)
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].id, "local-session")
        XCTAssertEqual(snapshot.sessions[0].status, .working)
        XCTAssertEqual(snapshot.sessions[0].cache.cachedReadTokens, 8_000)
    }

    func testLocalOnlyUsesInjectedLocalReader() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let updatedAt = Date(timeIntervalSince1970: 1_999)
        let connector = OpenCodeConnector(
            localStore: FakeOpenCodeLocalReader(snapshotValue: OpenCodeLocalSnapshot(
                isAvailable: true,
                sessions: [localSession(id: "local-session", status: .working, at: updatedAt)],
                updatedAt: updatedAt
            )),
            now: { now }
        )
        await connector.setSourceMode(.localOnly)

        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.map(\.id), ["local-session"])
        XCTAssertEqual(snapshot.updatedAt, updatedAt)
    }

    func testRealtimeOnlySkipsLocalReader() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let connector = OpenCodeConnector(
            localStore: FakeOpenCodeLocalReader(snapshotValue: OpenCodeLocalSnapshot(
                isAvailable: true,
                sessions: [localSession(id: "local-session", status: .working, at: now)],
                updatedAt: now
            )),
            now: { now }
        )
        await connector.setSourceMode(.realtimeOnly)

        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .unavailable)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testLivePayloadReplacesLocalSessionWithSameID() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let connector = OpenCodeConnector(
            localStore: FakeOpenCodeLocalReader(snapshotValue: OpenCodeLocalSnapshot(
                isAvailable: true,
                sessions: [localSession(
                    id: "session-1",
                    status: .waitingForApproval,
                    at: Date(timeIntervalSince1970: 1_990)
                )],
                updatedAt: Date(timeIntervalSince1970: 1_990)
            )),
            now: { now }
        )
        let report = OpenCodeSessionReport(
            id: "session-1",
            title: "Live work",
            projectPath: "/tmp/AgentHearth",
            status: .working,
            lastActivityAt: 1_999_000,
            cache: OpenCodeCacheReport(temperature: .warm)
        )

        try await connector.ingest(payload(sentAt: 1_999_000, sessions: [report]))
        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.sessions.map(\.id), ["session-1"])
        XCTAssertEqual(snapshot.sessions[0].status, .working)
        XCTAssertEqual(snapshot.sessions[0].title, "Live work")
    }

    private func localSession(id: String, status: SessionStatus, at date: Date) -> AgentSession {
        AgentSession(
            id: id,
            providerID: .openCode,
            title: "Local work",
            projectName: "AgentHearth",
            status: status,
            lastActivityAt: date
        )
    }

    private func payload(
        sentAt: Int64,
        sessions: [OpenCodeSessionReport]
    ) -> OpenCodePushPayload {
        OpenCodePushPayload(
            pluginVersion: "test",
            instance: "/tmp/project",
            sentAt: sentAt,
            sessions: sessions
        )
    }

    private func missingDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-Missing-\(UUID().uuidString)/opencode.db")
    }

    private func createOpenCodeDatabase(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        let sql = """
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, title TEXT, directory TEXT, model TEXT, time_updated INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session VALUES ('local-session', NULL, 'Local AgentHearth work', '/tmp/AgentHearth', '{"id":"gpt-5.6-sol","providerID":"openai"}', 1999000);
        INSERT INTO message VALUES ('message-1', 'local-session', 1999000, '{"role":"user","time":{"created":1999000}}');
        INSERT INTO message VALUES ('message-2', 'local-session', 1999500, '{"role":"assistant","modelID":"gpt-5.6-sol","providerID":"openai","time":{"created":1999500},"tokens":{"input":1000,"output":10,"cache":{"read":8000,"write":0}}}');
        """
        input.fileHandleForWriting.write(Data(sql.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private struct FakeOpenCodeLocalReader: OpenCodeLocalReading {
    let snapshotValue: OpenCodeLocalSnapshot

    func snapshot() -> OpenCodeLocalSnapshot { snapshotValue }
}
