import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class HistoryStoreTests: XCTestCase {
    func testStoresOneCompletedMeasurementAndComputesWeightedReuse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appending(path: "history.sqlite"))
        let time = Date.now.addingTimeInterval(-5)

        // `input` is fresh/uncached; total = input + cached. So total is 1000
        // (100 + 900) and 9000 (8100 + 900) respectively.
        let highReuse = snapshot(status: .completed, input: 100, cached: 900, output: 120, at: time)
        let lowerReuse = snapshot(id: "session-2", status: .idle, input: 8_100, cached: 900, output: 500, at: time.addingTimeInterval(1))
        await store.ingest([highReuse, lowerReuse], retentionDays: 30)
        await store.ingest([highReuse, lowerReuse], retentionDays: 30)

        let dashboard = await store.dashboard(days: 7, cacheHitThreshold: 0.80, now: .now)
        XCTAssertEqual(dashboard.turnCount, 2)
        XCTAssertEqual(dashboard.hitCount, 1)
        XCTAssertEqual(dashboard.inputTokens, 10_000)
        XCTAssertEqual(dashboard.cachedInputTokens, 1_800)
        XCTAssertEqual(dashboard.uncachedInputTokens, 8_200)
        XCTAssertEqual(dashboard.outputTokens, 620)
        XCTAssertEqual(try XCTUnwrap(dashboard.cacheReuseRate), 0.18, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(dashboard.hitRate), 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(dashboard.storageBytes, 0)
    }

    func testSkipsWorkingMeasurementsUntilTurnCompletes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appending(path: "history.sqlite"))
        let time = Date.now.addingTimeInterval(-5)
        await store.ingest([snapshot(status: .working, input: 1_000, cached: 990, output: 10, at: time)], retentionDays: 30)
        let whileWorking = await store.dashboard(days: 7)
        XCTAssertEqual(whileWorking.turnCount, 0)

        await store.ingest([snapshot(status: .completed, input: 1_000, cached: 990, output: 10, at: time)], retentionDays: 30)
        let completed = await store.dashboard(days: 7)
        XCTAssertEqual(completed.turnCount, 1)
        await store.clear()
        let cleared = await store.dashboard(days: 7)
        XCTAssertEqual(cleared.turnCount, 0)
    }

    func testFiltersByProviderAndRanksProjectsByUncachedInput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appending(path: "history.sqlite"))
        let time = Date.now.addingTimeInterval(-5)

        let codex = snapshot(
            id: "codex-app",
            providerID: .codex,
            projectName: "AgentHearth",
            status: .completed,
            input: 100,
            cached: 900,
            output: 100,
            at: time
        )
        let claude = snapshot(
            id: "claude-docs",
            providerID: .claudeCode,
            projectName: "Documentation",
            status: .completed,
            input: 800,
            cached: 200,
            output: 100,
            at: time.addingTimeInterval(1)
        )
        await store.ingest([codex, claude], retentionDays: 30)

        let allProviders = await store.dashboard(days: 7, cacheHitThreshold: 0.80)
        XCTAssertEqual(allProviders.projects.map(\.projectName), ["Documentation", "AgentHearth"])
        XCTAssertEqual(allProviders.projects.first?.uncachedInputTokens, 800)

        let codexOnly = await store.dashboard(days: 7, providerID: .codex, cacheHitThreshold: 0.80)
        XCTAssertEqual(codexOnly.turnCount, 1)
        XCTAssertEqual(codexOnly.projects.map(\.projectName), ["AgentHearth"])
        XCTAssertEqual(codexOnly.projects.first?.cacheReuseRate, 0.9)
    }

    /// Regression: `external_id` derives from `lastActivityAt`, which hook
    /// events move forward. When the hook aged out, the same terminal counters
    /// came back under the earlier transcript timestamp and were stored again.
    func testDoesNotDoubleCountATurnWhoseActivityTimestampShifts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appending(path: "history.sqlite"))
        let transcriptTime = Date.now.addingTimeInterval(-3 * 60 * 60)
        let hookTime = transcriptTime.addingTimeInterval(4)

        await store.ingest([snapshot(status: .idle, input: 100, cached: 900, output: 50, at: hookTime)], retentionDays: 30)
        // Two hours later the hook is pruned and the activity time reverts.
        await store.ingest([snapshot(status: .idle, input: 100, cached: 900, output: 50, at: transcriptTime)], retentionDays: 30)
        let afterShift = await store.dashboard(days: 7)
        XCTAssertEqual(afterShift.turnCount, 1)

        // A genuinely new turn (different counters) is still stored.
        await store.ingest([snapshot(status: .idle, input: 120, cached: 1_000, output: 80, at: transcriptTime.addingTimeInterval(60))], retentionDays: 30)
        let afterNewTurn = await store.dashboard(days: 7)
        XCTAssertEqual(afterNewTurn.turnCount, 2)

        // Identical counters well outside the hook window are a new turn too.
        await store.ingest([snapshot(status: .idle, input: 120, cached: 1_000, output: 80, at: transcriptTime.addingTimeInterval(2 * 60 * 60 + 120))], retentionDays: 30)
        let afterRepeat = await store.dashboard(days: 7)
        XCTAssertEqual(afterRepeat.turnCount, 3)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentHearth-HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func snapshot(
        id: String = "session-1",
        providerID: AgentProviderID = .codex,
        projectName: String = "AgentHearth",
        status: SessionStatus,
        input: Int,
        cached: Int,
        output: Int,
        at: Date
    ) -> ProviderSnapshot {
        ProviderSnapshot(id: providerID, connectionState: .connected, sessions: [
            AgentSession(id: id, providerID: providerID, title: "AgentHearth history", projectName: projectName, model: "gpt-test", status: status, lastActivityAt: at, cache: CacheSnapshot(temperature: .cold, inputTokens: input, outputTokens: output, cachedReadTokens: cached), target: SessionTarget(providerID: providerID, sessionID: id))
        ], usageWindows: [], updatedAt: at)
    }
}
