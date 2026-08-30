import AgentHearthApplication
import AgentHearthDomain
import Foundation

public actor CodexConnector: ProviderConnector {
    public nonisolated let providerID = AgentProviderID.codex

    private let sessionsURL: URL
    private let relevantAge: TimeInterval
    private let hookFreshness: TimeInterval
    private let stuckAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private var sourceMode = ProviderDataSourceMode.automatic
    private var hookEventsBySession: [String: CodexHookEvent] = [:]

    // Rollout files are append-only history: a file whose modification date
    // and size are unchanged decodes to the same summary, so polling reuses
    // it instead of re-reading the file. Session status is still recomputed
    // each poll because it depends on the current clock and live hook events.
    private var summariesByPath: [String: CachedRolloutSummary] = [:]
    private(set) var rolloutDecodeCount = 0

    public init(
        sessionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions"),
        relevantAge: TimeInterval = 7 * 24 * 60 * 60,
        hookFreshness: TimeInterval = 2 * 60 * 60,
        stuckAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.sessionsURL = sessionsURL
        self.relevantAge = relevantAge
        self.hookFreshness = hookFreshness
        self.stuckAfter = stuckAfter
        self.now = now
        self.fileManager = fileManager
    }

    public func setSourceMode(_ mode: ProviderDataSourceMode) {
        sourceMode = mode
    }

    public func ingest(_ event: CodexHookEvent) throws {
        guard event.schemaVersion == CodexHookEvent.supportedSchemaVersion else {
            throw CodexHookEventError.unsupportedSchema(event.schemaVersion)
        }
        guard !event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexHookEventError.invalidSession
        }
        if let existing = hookEventsBySession[event.sessionID], existing.sentAt > event.sentAt { return }
        hookEventsBySession[event.sessionID] = event
        pruneHookEvents()
    }

    public func snapshot() async throws -> ProviderSnapshot {
        pruneHookEvents()
        let hasLocalStore = fileManager.fileExists(atPath: sessionsURL.path)
        let files = sourceMode.usesLocalData && hasLocalStore ? recentRolloutFiles() : []
        pruneSummaries(keeping: files)
        let parsed = files.compactMap(parse)
        // A Codex session can have more than one recent rollout file after a
        // resume or compaction. Keep the newest observation instead of
        // trapping on duplicate stable session IDs.
        var sessionsByID = Dictionary(
            parsed.compactMap(\.session).map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.lastActivityAt > current.lastActivityAt ? candidate : current
            }
        )
        if sourceMode.usesRealtimeData {
            for event in hookEventsBySession.values {
                if let local = sessionsByID[event.sessionID] {
                    sessionsByID[event.sessionID] = merging(local, with: event)
                } else if let live = normalizeHookOnly(event) {
                    sessionsByID[event.sessionID] = live
                }
            }
        }
        let sessions = sessionsByID.values.sortedWorkingFirst()
        let newestUsage = parsed.compactMap(\.usage).max { $0.measuredAt < $1.measuredAt }
        let hasRealtimeData = sourceMode.usesRealtimeData && !hookEventsBySession.isEmpty
        let connected = (sourceMode.usesLocalData && hasLocalStore) || hasRealtimeData
        let latestHookAt = hookEventsBySession.values
            .map { Date(millisecondsSince1970: $0.sentAt) }
            .max()

        let updatedAt = max(parsed.map(\.modifiedAt).max() ?? .distantPast, latestHookAt ?? .distantPast)
        return ProviderSnapshot(
            id: providerID,
            connectionState: connected ? .connected : .unavailable,
            sessions: sessions,
            usageWindows: newestUsage?.windows ?? [],
            updatedAt: updatedAt == .distantPast ? now() : updatedAt
        )
    }

    private func recentRolloutFiles() -> [FileCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now().addingTimeInterval(-relevantAge)
        var candidates: [FileCandidate] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff
            else { continue }
            candidates.append(FileCandidate(url: url, modifiedAt: modifiedAt, fileSize: values.fileSize ?? 0))
        }
        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(50).map { $0 }
    }

    private func parse(_ candidate: FileCandidate) -> ParsedRollout? {
        guard let summary = summarizeReusingCache(candidate) else { return nil }

        let resolvedID = summary.sessionID ?? candidate.url.deletingPathExtension().lastPathComponent
        let directory = summary.cwd.map { URL(fileURLWithPath: $0) }
        let activityAt = max(
            summary.lastLifecycleAt ?? .distantPast,
            summary.latestTokenRecord?.0 ?? .distantPast,
            candidate.modifiedAt
        )
        let cache = makeCache(from: summary.latestTokenRecord, model: summary.model)
        let status = makeStatus(
            lastLifecycleEvent: summary.lastLifecycleEvent,
            reason: summary.lastLifecycleReason,
            activityAt: activityAt
        )
        let session = AgentSession(
            id: resolvedID,
            providerID: providerID,
            title: directory.map { "Codex · \($0.lastPathComponent)" } ?? "Codex session",
            projectName: directory?.lastPathComponent,
            model: summary.model,
            status: status,
            lastActivityAt: activityAt,
            cache: cache,
            cacheHealth: summary.cacheEvidence.snapshot(measuredAt: activityAt),
            target: SessionTarget(
                providerID: providerID,
                sessionID: resolvedID,
                workingDirectory: directory
            )
        )

        return ParsedRollout(
            session: session,
            usage: summary.latestTokenRecord.flatMap { makeUsage(rateLimits: $0.2, measuredAt: $0.0) },
            modifiedAt: candidate.modifiedAt
        )
    }

    private func summarizeReusingCache(_ candidate: FileCandidate) -> CodexRolloutSummary? {
        if let cached = summariesByPath[candidate.url.path],
           cached.modifiedAt == candidate.modifiedAt,
           cached.fileSize == candidate.fileSize {
            return cached.summary
        }
        let summary = summarize(candidate)
        summariesByPath[candidate.url.path] = CachedRolloutSummary(
            modifiedAt: candidate.modifiedAt,
            fileSize: candidate.fileSize,
            summary: summary
        )
        return summary
    }

    private func pruneSummaries(keeping candidates: [FileCandidate]) {
        let livePaths = Set(candidates.map(\.url.path))
        summariesByPath = summariesByPath.filter { livePaths.contains($0.key) }
    }

    /// Folds the rollout into facts that depend only on the file contents,
    /// never on the clock or live hook state, so the result stays valid for
    /// as long as the file itself is unchanged.
    private func summarize(_ candidate: FileCandidate) -> CodexRolloutSummary? {
        rolloutDecodeCount += 1
        let records = BoundedJSONLReader.decode(CodexRolloutRecord.self, from: candidate.url)
        guard !records.isEmpty else { return nil }

        var sessionID: String?
        var cwd: String?
        var model: String?
        var lastLifecycleEvent: String?
        var lastLifecycleReason: String?
        var lastLifecycleAt: Date?
        var latestTokenRecord: (Date, CodexTokenInfo, CodexRateLimits?)?
        var cacheEvidence = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .previousTurn, tokenTotals: .always)
        )

        for record in records {
            let timestamp = record.timestamp.flatMap(Self.parseDate)
            switch record.type {
            case "session_meta":
                sessionID = record.payload?.id ?? sessionID
                cwd = record.payload?.cwd ?? cwd
            case "turn_context":
                cwd = record.payload?.cwd ?? cwd
                model = record.payload?.model ?? model
            case "event_msg":
                guard let event = record.payload?.type else { continue }
                if event == "task_started" || event == "task_complete" || event == "turn_aborted" {
                    lastLifecycleEvent = event
                    lastLifecycleReason = record.payload?.reason
                    lastLifecycleAt = timestamp ?? lastLifecycleAt
                }
                if event == "token_count", let info = record.payload?.info, let timestamp {
                    latestTokenRecord = (timestamp, info, record.payload?.rateLimits)
                    if let observation = Self.evidenceObservation(
                        for: info.lastTokenUsage,
                        at: timestamp,
                        model: model
                    ) {
                        cacheEvidence.observe(observation)
                    }
                }
            default:
                continue
            }
        }

        return CodexRolloutSummary(
            sessionID: sessionID,
            cwd: cwd,
            model: model,
            lastLifecycleEvent: lastLifecycleEvent,
            lastLifecycleReason: lastLifecycleReason,
            lastLifecycleAt: lastLifecycleAt,
            latestTokenRecord: latestTokenRecord,
            cacheEvidence: cacheEvidence
        )
    }

    private func makeStatus(
        lastLifecycleEvent: String?,
        reason: String?,
        activityAt: Date
    ) -> SessionStatus {
        switch lastLifecycleEvent {
        case "task_started":
            return now().timeIntervalSince(activityAt) >= stuckAfter ? .stuck : .working
        case "turn_aborted":
            return reason == "interrupted" ? .idle : .failed
        case "task_complete":
            return .idle
        default:
            return .idle
        }
    }

    private func makeCache(
        from tokenRecord: (Date, CodexTokenInfo, CodexRateLimits?)?,
        model: String?
    ) -> CacheSnapshot {
        guard let tokenRecord, let usage = tokenRecord.1.lastTokenUsage else { return .unknown }
        let cached = max(0, usage.cachedInputTokens ?? 0)
        let written = max(0, usage.cacheWriteInputTokens ?? 0)
        let age = max(0, Int(now().timeIntervalSince(tokenRecord.0)))

        // Codex does not serialize the request's explicit cache policy. GPT-5.6+
        // uses the documented 30-minute policy; older/unknown models retain a
        // conservative five-minute fallback and remain marked as inferred.
        let inferredTTL = CacheTTLPolicy.ttlSeconds(openAIModel: model)
        let hasExactTTL = CacheTTLPolicy.hasDocumentedTTL(openAIModel: model)
        let remaining = max(0, inferredTTL - age)
        let temperature: CacheTemperature
        if remaining == 0 {
            temperature = .cold
        } else if remaining <= 60 {
            temperature = .expiring
        } else if cached > 0 || written > 0 {
            temperature = .warm
        } else {
            temperature = .unknown
        }

        // Codex/OpenAI report `input_tokens` INCLUDING the cached portion,
        // unlike Claude where it is fresh-only. Subtract the cached tokens so
        // CacheSnapshot.inputTokens uniformly means fresh/uncached across every
        // provider — otherwise the additive reuse math double-counts the cache.
        let freshInput = usage.inputTokens.map { max(0, $0 - cached) }

        return CacheSnapshot(
            temperature: temperature,
            remainingSeconds: temperature == .unknown ? nil : remaining,
            ttlSeconds: inferredTTL,
            inputTokens: freshInput,
            outputTokens: usage.outputTokens,
            cachedReadTokens: cached,
            cacheWriteTokens: written,
            lastConfirmedAt: cached > 0 ? tokenRecord.0 : nil,
            confidence: hasExactTTL ? .exactPolicy : (cached > 0 ? .observed : .inferred),
            reason: hasExactTTL
                ? "Codex rollout telemetry; GPT-5.6 uses the documented 30-minute cache TTL"
                : "Codex rollout token telemetry; expiry is inferred from the model family"
        )
    }

    private func merging(_ local: AgentSession, with event: CodexHookEvent) -> AgentSession {
        let liveAt = Date(millisecondsSince1970: event.sentAt)
        guard liveAt >= local.lastActivityAt.addingTimeInterval(-2) else { return local }
        let directory = event.workingDirectory.map { URL(fileURLWithPath: $0) }
        return AgentSession(
            id: local.id,
            providerID: providerID,
            title: local.title,
            projectName: local.projectName ?? directory?.lastPathComponent,
            model: event.model ?? local.model,
            status: statusFromHook(event),
            lastActivityAt: max(local.lastActivityAt, liveAt),
            cache: local.cache,
            cacheHealth: local.cacheHealth,
            target: local.target ?? SessionTarget(
                providerID: providerID,
                sessionID: local.id,
                workingDirectory: directory
            )
        )
    }

    private func normalizeHookOnly(_ event: CodexHookEvent) -> AgentSession? {
        let status = statusFromHook(event)
        guard status == .working || status.requiresAttention else { return nil }
        let activityAt = Date(millisecondsSince1970: event.sentAt)
        let directory = event.workingDirectory.map { URL(fileURLWithPath: $0) }
        return AgentSession(
            id: event.sessionID,
            providerID: providerID,
            title: directory.map { "Codex · \($0.lastPathComponent)" } ?? "Codex session",
            projectName: directory?.lastPathComponent,
            model: event.model,
            status: status,
            lastActivityAt: activityAt,
            target: SessionTarget(
                providerID: providerID,
                sessionID: event.sessionID,
                workingDirectory: directory
            )
        )
    }

    private func statusFromHook(_ event: CodexHookEvent) -> SessionStatus {
        let activityAt = Date(millisecondsSince1970: event.sentAt)
        switch event.eventName {
        case "SessionStart", "UserPromptSubmit":
            return now().timeIntervalSince(activityAt) >= stuckAfter ? .stuck : .working
        case "PermissionRequest":
            return .waitingForApproval
        case "Stop":
            return .idle
        case "SessionEnd":
            return .completed
        default:
            return .idle
        }
    }

    private func pruneHookEvents() {
        let cutoff = Int64(now().addingTimeInterval(-hookFreshness).timeIntervalSince1970 * 1_000)
        hookEventsBySession = hookEventsBySession.filter { $0.value.sentAt >= cutoff }
    }

    private func makeUsage(rateLimits: CodexRateLimits?, measuredAt: Date) -> MeasuredUsage? {
        guard let rateLimits else { return nil }
        let windows = [rateLimits.primary, rateLimits.secondary].compactMap { window -> UsageWindow? in
            guard let window, let usedPercent = window.usedPercent else { return nil }
            let minutes = window.windowMinutes ?? 0
            let label: String
            switch minutes {
            case 300: label = "5 hours"
            case 10_080: label = "7 days"
            default: label = minutes > 0 ? "\(minutes) minutes" : "Usage"
            }
            return UsageWindow(
                id: "codex-\(minutes)",
                label: label,
                usedFraction: usedPercent / 100,
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                measuredAt: measuredAt
            )
        }
        return windows.isEmpty ? nil : MeasuredUsage(windows: windows, measuredAt: measuredAt)
    }

}
