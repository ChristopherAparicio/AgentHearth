import AgentHearthApplication
import AgentHearthDomain
import Foundation
import SQLite3

struct OpenCodeLocalSnapshot: Sendable {
    let isAvailable: Bool
    let sessions: [AgentSession]
    let updatedAt: Date
}

/// Seam over the local OpenCode SQLite database so `OpenCodeConnector`'s
/// local branch can be exercised without a real database file.
protocol OpenCodeLocalReading: Sendable {
    func snapshot() -> OpenCodeLocalSnapshot
}

struct OpenCodeLocalStore: OpenCodeLocalReading, @unchecked Sendable {
    let databaseURL: URL
    let relevantAge: TimeInterval
    let stuckAfter: TimeInterval
    let now: @Sendable () -> Date

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db"),
        relevantAge: TimeInterval = 7 * 24 * 60 * 60,
        stuckAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.relevantAge = relevantAge
        self.stuckAfter = stuckAfter
        self.now = now
    }

    func snapshot() -> OpenCodeLocalSnapshot {
        guard let resolvedDatabaseURL = resolvedDatabaseURL() else {
            return OpenCodeLocalSnapshot(isAvailable: false, sessions: [], updatedAt: now())
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            resolvedDatabaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return OpenCodeLocalSnapshot(isAvailable: false, sessions: [], updatedAt: now())
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let rows = recentSessions(in: database)
        let sessions = rows.compactMap { normalize($0, messages: recentMessages(in: database, sessionID: $0.id)) }
            .sortedWorkingFirst()
        return OpenCodeLocalSnapshot(
            isAvailable: true,
            sessions: sessions,
            updatedAt: sessions.map(\.lastActivityAt).max() ?? now()
        )
    }

    private func resolvedDatabaseURL() -> URL? {
        let directory = databaseURL.deletingLastPathComponent()
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("opencode")
        } ?? []
        if candidates.isEmpty {
            return FileManager.default.fileExists(atPath: databaseURL.path) ? databaseURL : nil
        }
        return candidates.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            return left < right
        }
    }

    private func recentSessions(in database: OpaquePointer) -> [SessionRow] {
        let query = """
        SELECT id, title, directory, time_updated
        FROM session
        WHERE parent_id IS NULL AND time_updated >= ?
        ORDER BY time_updated DESC
        LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        let cutoff = Int64(now().addingTimeInterval(-relevantAge).timeIntervalSince1970 * 1_000)
        sqlite3_bind_int64(statement, 1, cutoff)

        var rows: [SessionRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, column: 0),
                  let directory = text(statement, column: 2)
            else { continue }
            rows.append(SessionRow(
                id: id,
                title: text(statement, column: 1) ?? id,
                directory: directory,
                updatedAtMilliseconds: sqlite3_column_int64(statement, 3)
            ))
        }
        return rows
    }

    private func recentMessages(in database: OpaquePointer, sessionID: String) -> [StoredMessage] {
        let query = """
        SELECT
          json_extract(data, '$.role'),
          json_extract(data, '$.modelID'),
          json_extract(data, '$.providerID'),
          json_extract(data, '$.time.created'),
          json_extract(data, '$.time.completed'),
          json_extract(data, '$.tokens.input'),
          json_extract(data, '$.tokens.output'),
          json_extract(data, '$.tokens.reasoning'),
          json_extract(data, '$.tokens.cache.read'),
          json_extract(data, '$.tokens.cache.write'),
          json_extract(data, '$.finish')
        FROM message
        WHERE session_id = ?
        ORDER BY time_created DESC, id DESC
        LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sessionID.withCString { value in
            sqlite3_bind_text(statement, 1, value, -1, sqliteTransient)
        }

        var messages: [StoredMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let role = text(statement, column: 0) else { continue }
            let input = integer(statement, column: 5).map(Int.init)
            let output = integer(statement, column: 6).map(Int.init)
            let reasoning = integer(statement, column: 7).map(Int.init)
            let cacheRead = integer(statement, column: 8).map(Int.init)
            let cacheWrite = integer(statement, column: 9).map(Int.init)
            let tokens: StoredMessage.MessageTokens? = if input != nil || output != nil
                || reasoning != nil || cacheRead != nil || cacheWrite != nil {
                StoredMessage.MessageTokens(
                    input: input,
                    output: output,
                    reasoning: reasoning,
                    cache: cacheRead != nil || cacheWrite != nil
                        ? StoredMessage.MessageTokens.CacheTokens(read: cacheRead, write: cacheWrite)
                        : nil
                )
            } else {
                nil
            }
            messages.append(StoredMessage(
                role: role,
                modelID: text(statement, column: 1),
                providerID: text(statement, column: 2),
                time: StoredMessage.MessageTime(
                    created: integer(statement, column: 3),
                    completed: integer(statement, column: 4)
                ),
                tokens: tokens,
                finish: text(statement, column: 10)
            ))
        }
        return Array(messages.reversed())
    }

    private func normalize(_ row: SessionRow, messages: [StoredMessage]) -> AgentSession? {
        let latest = messages.last
        let latestAssistant = messages.last(where: { $0.role == "assistant" })
        let updatedAt = Date(millisecondsSince1970: row.updatedAtMilliseconds)
        let messageActivity = latest?.activityAt
        let activityAt = max(updatedAt, messageActivity ?? .distantPast)
        let status: SessionStatus
        if latest?.finish == "error" {
            status = .failed
        } else if latest?.role == "user" || (latest?.role == "assistant" && latest?.time?.completed == nil) {
            status = now().timeIntervalSince(activityAt) >= stuckAfter ? .stuck : .working
        } else {
            status = .idle
        }

        let model = latestAssistant?.modelID
        let provider = latestAssistant?.providerID
        let cache = makeCache(latestAssistant, model: model, provider: provider)
        let evidence = makeEvidence(messages)
        let directory = URL(fileURLWithPath: row.directory)
        return AgentSession(
            id: row.id,
            providerID: .openCode,
            title: row.title.isEmpty ? row.id : row.title,
            projectName: directory.lastPathComponent,
            model: model,
            status: status,
            lastActivityAt: activityAt,
            cache: cache,
            cacheHealth: evidence,
            target: SessionTarget(
                providerID: .openCode,
                sessionID: row.id,
                workingDirectory: directory
            )
        )
    }

    private func makeCache(
        _ message: StoredMessage?,
        model: String?,
        provider: String?
    ) -> CacheSnapshot {
        guard let message, let usage = message.tokens else { return .unknown }
        let confirmedAt = message.completedAt ?? message.createdAt
        let expiry = OpenCodeCacheExpiry(
            provider: provider,
            model: model,
            confirmedAt: confirmedAt,
            now: now()
        )
        let read = max(0, usage.cache?.read ?? 0)
        let write = max(0, usage.cache?.write ?? 0)
        return CacheSnapshot(
            temperature: expiry.temperature,
            remainingSeconds: expiry.remainingSeconds,
            ttlSeconds: expiry.ttlSeconds,
            inputTokens: usage.input,
            outputTokens: usage.output,
            cachedReadTokens: read,
            cacheWriteTokens: write,
            lastConfirmedAt: read > 0 || write > 0 ? confirmedAt : nil,
            confidence: read > 0 ? .observed : .inferred,
            reason: "OpenCode local SQLite token telemetry; expiry is inferred"
        )
    }

    /// Only assistant messages carrying token telemetry participate; unlike
    /// the HTTP server path, telemetry-free messages neither count as unknown
    /// nor become the reference turn, and eligibility does not require a
    /// stable model.
    private func makeEvidence(_ messages: [StoredMessage]) -> CacheHealthSnapshot? {
        var evidence = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .currentTurn))
        for message in messages where message.role == "assistant" && message.tokens != nil {
            evidence.observe(CacheEvidenceAccumulator.TurnObservation(
                startedAt: message.createdAt,
                endedAt: message.completedAt,
                cachedReadTokens: message.tokens?.cache?.read ?? 0,
                ttl: TimeInterval(
                    CacheTTLPolicy.ttlSeconds(provider: message.providerID, model: message.modelID)
                )
            ))
        }
        return evidence.snapshot(measuredAt: messages.last?.activityAt ?? now())
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func integer(_ statement: OpaquePointer, column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct SessionRow {
    let id: String
    let title: String
    let directory: String
    let updatedAtMilliseconds: Int64
}

private struct StoredMessage {
    let role: String
    let modelID: String?
    let providerID: String?
    let time: MessageTime?
    let tokens: MessageTokens?
    let finish: String?

    var createdAt: Date? {
        time?.created.map { Date(millisecondsSince1970: $0) }
    }

    var completedAt: Date? {
        time?.completed.map { Date(millisecondsSince1970: $0) }
    }

    var activityAt: Date? { completedAt ?? createdAt }

    struct MessageTime {
        let created: Int64?
        let completed: Int64?
    }

    struct MessageTokens {
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: CacheTokens?

        struct CacheTokens {
            let read: Int?
            let write: Int?
        }
    }
}
