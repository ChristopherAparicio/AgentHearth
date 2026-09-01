import AgentHearthApplication
import AgentHearthDomain
import Foundation
import SQLite3

/// Stores a final raw-token measurement per provider turn. Counter-only history
/// is intentionally rebuilt at schema v2 because it cannot yield a truthful
/// cache-reuse percentage.
public actor HistoryStore {
    /// A turn counts as a cache hit when its cached share of the input meets
    /// the bound threshold parameter. The division is safe only because the
    /// ingest path stores rows with `input_tokens > 0` (fresh + cache-read +
    /// cache-write).
    private static let hitRatioMeetsThresholdSQL = "CAST(cached_input_tokens AS REAL)/input_tokens>=?"

    private let databaseURL: URL
    nonisolated(unsafe) private var database: OpaquePointer?
    private var lastPrunedAt: Date?

    public init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/AgentHearth/history.sqlite")) {
        self.databaseURL = databaseURL
    }

    deinit { if let database { sqlite3_close(database) } }

    public func ingest(_ snapshots: [ProviderSnapshot], retentionDays: Int) {
        guard let database = openDatabase() else { return }
        sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
        for session in snapshots.flatMap(\.sessions) {
            // Working sessions often emit progressive totals. Wait for the
            // terminal state to avoid treating one turn as several turns.
            guard [.idle, .completed, .failed].contains(session.status) else { continue }
            // A turn served entirely from cache has fresh input 0 but is still a
            // real (perfect-reuse) turn, so gate on the full prompt size.
            let fresh = max(0, session.cache.inputTokens ?? 0)
            let cached = max(0, session.cache.cachedReadTokens ?? 0)
            let written = max(0, session.cache.cacheWriteTokens ?? 0)
            guard fresh + cached + written > 0 else { continue }
            insertMeasurement(database: database, session: session, inputTokens: fresh)
        }
        let pruned = prune(database: database, retentionDays: retentionDays)
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
        // A checkpoint cannot make progress inside the write transaction it is
        // issued from, so it only runs once the pruning commit has landed.
        if pruned { sqlite3_exec(database, "PRAGMA wal_checkpoint(PASSIVE)", nil, nil, nil) }
    }

    public func dashboard(
        days: Int,
        providerID: AgentProviderID? = nil,
        cacheHitThreshold: Double = 0.80,
        now: Date = .now
    ) -> HistoryDashboardSnapshot {
        let end = now
        let start = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -max(1, days), to: end)
            ?? end.addingTimeInterval(-TimeInterval(max(1, days) * 86_400))
        return dashboard(
            startsAt: start,
            endsAt: end,
            providerID: providerID,
            cacheHitThreshold: cacheHitThreshold
        )
    }

    public func dashboard(
        startsAt: Date,
        endsAt: Date,
        providerID: AgentProviderID? = nil,
        cacheHitThreshold: Double = 0.80
    ) -> HistoryDashboardSnapshot {
        guard let database = openDatabase() else { return .empty }
        let threshold = min(1, max(0, cacheHitThreshold))
        return HistoryDashboardSnapshot(
            startsAt: startsAt,
            endsAt: endsAt,
            buckets: loadBuckets(
                database: database,
                start: startsAt,
                end: endsAt,
                providerID: providerID,
                threshold: threshold
            ),
            sessions: loadSessions(
                database: database,
                start: startsAt,
                end: endsAt,
                providerID: providerID,
                threshold: threshold
            ),
            projects: loadProjects(
                database: database,
                start: startsAt,
                end: endsAt,
                providerID: providerID,
                threshold: threshold
            ),
            storageBytes: fileSize()
        )
    }

    public func clear() {
        guard let database = openDatabase() else { return }
        sqlite3_exec(database, "DELETE FROM cache_events; VACUUM;", nil, nil, nil)
    }

    public func applyRetention(days: Int) {
        guard let database = openDatabase() else { return }
        if prune(database: database, retentionDays: days, force: true) {
            sqlite3_exec(database, "PRAGMA wal_checkpoint(PASSIVE)", nil, nil, nil)
        }
    }

    private func openDatabase() -> OpaquePointer? {
        if let database { return database }
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else { return nil }
        sqlite3_busy_timeout(handle, 500)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
        let version = schemaVersion(handle)
        if version < 2 {
            sqlite3_exec(handle, "DROP TABLE IF EXISTS cache_events; DROP TABLE IF EXISTS session_state;", nil, nil, nil)
        }
        sqlite3_exec(handle, """
        CREATE TABLE IF NOT EXISTS cache_events (
          external_id TEXT PRIMARY KEY, session_key TEXT NOT NULL, provider TEXT NOT NULL,
          host_name TEXT NOT NULL, source_name TEXT, project_name TEXT NOT NULL,
          title TEXT NOT NULL, model TEXT,
          occurred_at_ms INTEGER NOT NULL, input_tokens INTEGER NOT NULL,
          cached_input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS cache_events_time ON cache_events(occurred_at_ms);
        CREATE INDEX IF NOT EXISTS cache_events_session ON cache_events(session_key, occurred_at_ms);
        """, nil, nil, nil)
        if version >= 2, version < 3 {
            sqlite3_exec(
                handle,
                "ALTER TABLE cache_events ADD COLUMN project_name TEXT NOT NULL DEFAULT 'Unassigned'",
                nil,
                nil,
                nil
            )
        }
        sqlite3_exec(handle, "PRAGMA user_version=3", nil, nil, nil)
        database = handle
        return handle
    }

    private func schemaVersion(_ database: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    private func insertMeasurement(database: OpaquePointer, session: AgentSession, inputTokens: Int) {
        let key = sessionKey(session)
        // `inputTokens` is the provider's raw (uncached) count, so the stored
        // total is fresh + cache-read + cache-creation. Storing the raw input
        // and clamping the cache to it reported 100% reuse for every turn.
        let rawInput = max(0, inputTokens)
        let cached = max(0, session.cache.cachedReadTokens ?? 0)
        let written = max(0, session.cache.cacheWriteTokens ?? 0)
        let totalInput = rawInput + cached + written
        let output = max(0, session.cache.outputTokens ?? 0)

        // The timestamp-based `external_id` alone is not enough for
        // idempotency: `lastActivityAt` also moves with hook events (which are
        // kept for two hours), so when a hook ages out the same last-turn
        // counters come back under an earlier timestamp and would be stored as
        // a second turn. A reading whose counters equal the latest recorded
        // row for the session, within that hook window, is the same turn.
        // Identical counters farther apart are treated as a genuine new turn.
        if matchesLatestMeasurement(
            database: database,
            sessionKey: key,
            occurredAt: milliseconds(session.lastActivityAt),
            inputTokens: totalInput,
            cachedInputTokens: cached,
            outputTokens: output
        ) {
            return
        }

        let externalID = "\(key):\(milliseconds(session.lastActivityAt))"
        let sql = """
        INSERT OR IGNORE INTO cache_events(
          external_id,session_key,provider,host_name,source_name,project_name,
          title,model,occurred_at_ms,input_tokens,cached_input_tokens,output_tokens
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(externalID, to: statement, at: 1); bind(key, to: statement, at: 2)
        bind(session.providerID.rawValue, to: statement, at: 3)
        bind(session.host.displayName, to: statement, at: 4)
        bindOptional(session.source?.displayName, to: statement, at: 5)
        bind(projectName(for: session), to: statement, at: 6)
        bind(session.title, to: statement, at: 7)
        bindOptional(session.model, to: statement, at: 8)
        sqlite3_bind_int64(statement, 9, milliseconds(session.lastActivityAt))
        sqlite3_bind_int64(statement, 10, Int64(totalInput))
        sqlite3_bind_int64(statement, 11, Int64(cached))
        sqlite3_bind_int64(statement, 12, Int64(output))
        sqlite3_step(statement)
    }

    /// Window within which a reading with identical counters is the same turn
    /// seen under a shifted timestamp (matches the connectors' hook retention).
    private static let sameTurnWindowMilliseconds: Int64 = 2 * 60 * 60 * 1_000

    /// Whether the most recent row for this session already carries exactly
    /// these last-turn counters and lies within `sameTurnWindowMilliseconds`
    /// of `occurredAt`. Uses the `(session_key, occurred_at_ms)` index.
    private func matchesLatestMeasurement(
        database: OpaquePointer,
        sessionKey: String,
        occurredAt: Int64,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Bool {
        let sql = """
        SELECT input_tokens,cached_input_tokens,output_tokens,occurred_at_ms FROM cache_events
        WHERE session_key=? ORDER BY occurred_at_ms DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(sessionKey, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let latestOccurredAt = sqlite3_column_int64(statement, 3)
        return sqlite3_column_int64(statement, 0) == Int64(inputTokens)
            && sqlite3_column_int64(statement, 1) == Int64(cachedInputTokens)
            && sqlite3_column_int64(statement, 2) == Int64(outputTokens)
            && abs(occurredAt - latestOccurredAt) <= Self.sameTurnWindowMilliseconds
    }

    /// Size of the database and its WAL/shm companions on disk.
    public func storageBytes() -> Int64 {
        fileSize()
    }

    private func loadBuckets(
        database: OpaquePointer,
        start: Date,
        end: Date,
        providerID: AgentProviderID?,
        threshold: Double
    ) -> [CacheHistoryBucket] {
        let sql = """
        SELECT strftime('%Y-%m-%d', occurred_at_ms/1000, 'unixepoch', 'localtime'),
               COUNT(*),SUM(CASE WHEN \(Self.hitRatioMeetsThresholdSQL) THEN 1 ELSE 0 END),
               SUM(input_tokens),SUM(cached_input_tokens),SUM(output_tokens)
        FROM cache_events
        WHERE occurred_at_ms>=? AND occurred_at_ms<? AND (? IS NULL OR provider=?)
        GROUP BY 1 ORDER BY 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bindQueryRange(statement, threshold: threshold, start: start, end: end, providerID: providerID)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var values: [CacheHistoryBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let label = text(statement, 0), let day = formatter.date(from: label) else { continue }
            values.append(CacheHistoryBucket(day: day, turnCount: Int(sqlite3_column_int64(statement, 1)), hitCount: Int(sqlite3_column_int64(statement, 2)), inputTokens: Int(sqlite3_column_int64(statement, 3)), cachedInputTokens: Int(sqlite3_column_int64(statement, 4)), outputTokens: Int(sqlite3_column_int64(statement, 5))))
        }
        return values
    }

    private func loadSessions(
        database: OpaquePointer,
        start: Date,
        end: Date,
        providerID: AgentProviderID?,
        threshold: Double
    ) -> [SessionHistorySummary] {
        let sql = """
        SELECT session_key,MAX(title),provider,MAX(host_name),MAX(source_name),COUNT(*),
               SUM(CASE WHEN \(Self.hitRatioMeetsThresholdSQL) THEN 1 ELSE 0 END),
               SUM(input_tokens),SUM(cached_input_tokens),SUM(output_tokens),MAX(occurred_at_ms)
        FROM cache_events
        WHERE occurred_at_ms>=? AND occurred_at_ms<? AND (? IS NULL OR provider=?)
        GROUP BY session_key,provider ORDER BY MAX(occurred_at_ms) DESC LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bindQueryRange(statement, threshold: threshold, start: start, end: end, providerID: providerID)
        var values: [SessionHistorySummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = text(statement, 0),
                  let title = text(statement, 1),
                  let rawProvider = text(statement, 2),
                  let provider = AgentProviderID(rawValue: rawProvider),
                  let host = text(statement, 3)
            else { continue }
            values.append(SessionHistorySummary(
                id: key,
                title: title,
                providerID: provider,
                hostName: host,
                sourceName: text(statement, 4),
                hitCount: Int(sqlite3_column_int64(statement, 6)),
                turnCount: Int(sqlite3_column_int64(statement, 5)),
                inputTokens: Int(sqlite3_column_int64(statement, 7)),
                cachedInputTokens: Int(sqlite3_column_int64(statement, 8)),
                outputTokens: Int(sqlite3_column_int64(statement, 9)),
                lastSeenAt: Date(millisecondsSince1970: sqlite3_column_int64(statement, 10))
            ))
        }
        return values
    }

    private func loadProjects(
        database: OpaquePointer,
        start: Date,
        end: Date,
        providerID: AgentProviderID?,
        threshold: Double
    ) -> [ProjectHistorySummary] {
        let sql = """
        SELECT project_name,COUNT(*),
               SUM(CASE WHEN \(Self.hitRatioMeetsThresholdSQL) THEN 1 ELSE 0 END),
               SUM(input_tokens),SUM(cached_input_tokens),SUM(output_tokens)
        FROM cache_events
        WHERE occurred_at_ms>=? AND occurred_at_ms<? AND (? IS NULL OR provider=?)
        GROUP BY project_name
        ORDER BY SUM(input_tokens)-SUM(cached_input_tokens) DESC, SUM(input_tokens) DESC
        LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        bindQueryRange(statement, threshold: threshold, start: start, end: end, providerID: providerID)
        var values: [ProjectHistorySummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let projectName = text(statement, 0) else { continue }
            values.append(ProjectHistorySummary(
                projectName: projectName,
                turnCount: Int(sqlite3_column_int64(statement, 1)),
                hitCount: Int(sqlite3_column_int64(statement, 2)),
                inputTokens: Int(sqlite3_column_int64(statement, 3)),
                cachedInputTokens: Int(sqlite3_column_int64(statement, 4)),
                outputTokens: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return values
    }

    private func bindQueryRange(
        _ statement: OpaquePointer,
        threshold: Double,
        start: Date,
        end: Date,
        providerID: AgentProviderID?
    ) {
        sqlite3_bind_double(statement, 1, threshold)
        sqlite3_bind_int64(statement, 2, milliseconds(start))
        sqlite3_bind_int64(statement, 3, milliseconds(end))
        bindOptional(providerID?.rawValue, to: statement, at: 4)
        bindOptional(providerID?.rawValue, to: statement, at: 5)
    }

    /// Deletes rows older than the retention window at most every six hours
    /// (always when `force`). Returns whether a pruning pass ran, so the caller
    /// can checkpoint the WAL once the surrounding transaction has committed.
    @discardableResult
    private func prune(database: OpaquePointer, retentionDays: Int, force: Bool = false) -> Bool {
        let now = Date.now
        if !force, let lastPrunedAt, now.timeIntervalSince(lastPrunedAt) < 6 * 60 * 60 { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM cache_events WHERE occurred_at_ms < ?", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, milliseconds(now.addingTimeInterval(-TimeInterval(max(1, retentionDays) * 86_400))))
        sqlite3_step(statement)
        lastPrunedAt = now
        return true
    }

    private func sessionKey(_ session: AgentSession) -> String { [session.providerID.rawValue, session.host.id, session.target?.sessionID ?? session.id].joined(separator: ":") }
    private func projectName(for session: AgentSession) -> String {
        let name = session.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Unassigned" : name
    }
    private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
    private func fileSize() -> Int64 {
        [databaseURL,
         URL(fileURLWithPath: databaseURL.path + "-wal"),
         URL(fileURLWithPath: databaseURL.path + "-shm")]
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransientHistory)
        }
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(value, to: statement, at: index)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

private let sqliteTransientHistory = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
