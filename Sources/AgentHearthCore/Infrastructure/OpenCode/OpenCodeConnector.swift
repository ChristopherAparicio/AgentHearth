import AgentHearthApplication
import AgentHearthDomain
import Foundation

public actor OpenCodeConnector: ProviderConnector {
    public nonisolated let providerID = AgentProviderID.openCode

    private let staleAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let localStore: any OpenCodeLocalReading
    private var sourceMode = ProviderDataSourceMode.automatic
    private var payloadsByInstance: [String: OpenCodePushPayload] = [:]

    public init(
        staleAfter: TimeInterval = 75,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db"),
        relevantAge: TimeInterval = 2 * 60 * 60,
        stuckAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            staleAfter: staleAfter,
            localStore: OpenCodeLocalStore(
                databaseURL: databaseURL,
                relevantAge: relevantAge,
                stuckAfter: stuckAfter,
                now: now
            ),
            now: now
        )
    }

    init(
        staleAfter: TimeInterval = 75,
        localStore: any OpenCodeLocalReading,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.staleAfter = staleAfter
        self.now = now
        self.localStore = localStore
    }

    public func setSourceMode(_ mode: ProviderDataSourceMode) {
        sourceMode = mode
    }

    public func ingest(_ payload: OpenCodePushPayload) throws {
        guard payload.schemaVersion == OpenCodePushPayload.supportedSchemaVersion else {
            throw OpenCodePayloadError.unsupportedSchema(payload.schemaVersion)
        }
        guard !payload.instance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenCodePayloadError.invalidInstance
        }

        payloadsByInstance[payload.instance] = payload
        pruneStalePayloads()
    }

    public func snapshot() async throws -> ProviderSnapshot {
        pruneStalePayloads()
        let livePayloads = Array(payloadsByInstance.values)
        let local = sourceMode.usesLocalData
            ? localStore.snapshot()
            : OpenCodeLocalSnapshot(isAvailable: false, sessions: [], updatedAt: .distantPast)

        var sessionsByID = Dictionary(uniqueKeysWithValues: local.sessions.map { ($0.id, $0) })
        if sourceMode.usesRealtimeData {
            var newestBySession: [String: OpenCodeSessionReport] = [:]
            for report in livePayloads.flatMap(\.sessions) {
                if let existing = newestBySession[report.id], existing.lastActivityAt >= report.lastActivityAt {
                    continue
                }
                newestBySession[report.id] = report
            }
            for report in newestBySession.values {
                sessionsByID[report.id] = normalize(report)
            }
        }

        let sessions = sessionsByID.values
            .filter(isRelevant)
            .sortedWorkingFirst()

        let liveUpdatedAt = livePayloads
            .map { Date(millisecondsSince1970: $0.sentAt) }
            .max() ?? .distantPast
        let hasRealtimeData = sourceMode.usesRealtimeData && !livePayloads.isEmpty
        let connected = local.isAvailable || hasRealtimeData

        let updatedAt = max(local.updatedAt, liveUpdatedAt)
        return ProviderSnapshot(
            id: providerID,
            connectionState: connected ? .connected : .unavailable,
            sessions: sessions,
            usageWindows: [],
            updatedAt: updatedAt == .distantPast ? now() : updatedAt
        )
    }

    private func pruneStalePayloads() {
        let current = now().timeIntervalSince1970
        payloadsByInstance = payloadsByInstance.filter { _, payload in
            current - (Double(payload.sentAt) / 1_000) <= staleAfter
        }
    }

    private func normalize(_ report: OpenCodeSessionReport) -> AgentSession {
        let cache = report.cache
        let evidenceCount = cache.hitCount
            + cache.avoidableMissCount
            + cache.expectedColdStartCount
            + cache.unknownCount
        let lastActivity = Date(millisecondsSince1970: report.lastActivityAt)
        let directory = URL(fileURLWithPath: report.projectPath)

        return AgentSession(
            id: report.id,
            providerID: providerID,
            title: report.title.isEmpty ? report.id : report.title,
            projectName: directory.lastPathComponent,
            model: report.model,
            status: normalize(report.status),
            lastActivityAt: lastActivity,
            cache: CacheSnapshot(
                temperature: cache.temperature,
                remainingSeconds: cache.remainingSeconds,
                ttlSeconds: cache.ttlSeconds,
                cachedReadTokens: cache.cachedReadTokens,
                cacheWriteTokens: cache.cacheWriteTokens,
                lastConfirmedAt: cache.cachedReadTokens > 0 ? lastActivity : nil,
                confidence: cache.cachedReadTokens > 0 ? .observed : .inferred,
                reason: report.provider.map { "OpenCode cache telemetry from \($0)" }
            ),
            cacheHealth: evidenceCount > 0 ? CacheHealthSnapshot(
                hitCount: cache.hitCount,
                avoidableMissCount: cache.avoidableMissCount,
                expectedColdStartCount: cache.expectedColdStartCount,
                unknownCount: cache.unknownCount,
                measuredAt: lastActivity
            ) : nil,
            target: SessionTarget(
                providerID: providerID,
                sessionID: report.id,
                workingDirectory: directory
            )
        )
    }

    private func normalize(_ status: OpenCodeReportedStatus) -> SessionStatus {
        switch status {
        case .working: .working
        case .waitingForApproval: .waitingForApproval
        case .idle: .idle
        case .stuck: .stuck
        case .failed: .failed
        }
    }

    private func isRelevant(_ session: AgentSession) -> Bool {
        if session.status == .working || session.status.requiresAttention {
            return true
        }
        return session.cache.temperature == .warm || session.cache.temperature == .expiring
    }
}
