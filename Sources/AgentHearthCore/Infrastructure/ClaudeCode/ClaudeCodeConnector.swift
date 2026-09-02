import AgentHearthApplication
import AgentHearthDomain
import Foundation

public actor ClaudeCodeConnector: ProviderConnector, AccountUsageIngesting {
    public nonisolated let providerID = AgentProviderID.claudeCode

    private let projectsURL: URL
    private let planUsageHistoryURL: URL
    private let relevantAge: TimeInterval
    private let hookFreshness: TimeInterval
    private let stuckAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private var sourceMode = ProviderDataSourceMode.automatic
    private var hookEventsBySession: [String: ClaudeCodeHookEvent] = [:]
    private var statusEventsBySession: [String: ClaudeCodeStatusEvent] = [:]

    // Transcripts are append-only history: a file whose modification date and
    // size are unchanged decodes to the same summary, so polling reuses it
    // instead of re-reading the file. Session status is still recomputed each
    // poll because it depends on the current clock and live hook events.
    private var summariesByPath: [String: CachedTranscriptSummary] = [:]
    private(set) var transcriptDecodeCount = 0

    // Claude Desktop's usage journal is re-parsed only when it changes, for the
    // same reason transcripts are cached: an unchanged file yields the same
    // sample.
    private var cachedPlanUsage: CachedPlanUsage?
    private(set) var planUsageDecodeCount = 0

    // Authoritative account usage from Anthropic's endpoint, injected by the
    // opt-in poller. Carries the reset timestamps no local source records.
    private var accountUsage: AccountUsage?

    public init(
        projectsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects"),
        planUsageHistoryURL: URL = PlanUsageHistoryReader.defaultURL,
        relevantAge: TimeInterval = 7 * 24 * 60 * 60,
        hookFreshness: TimeInterval = 2 * 60 * 60,
        stuckAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.projectsURL = projectsURL
        self.planUsageHistoryURL = planUsageHistoryURL
        self.relevantAge = relevantAge
        self.hookFreshness = hookFreshness
        self.stuckAfter = stuckAfter
        self.now = now
        self.fileManager = fileManager
    }

    public func setSourceMode(_ mode: ProviderDataSourceMode) {
        sourceMode = mode
    }

    /// Injects (or clears) the authoritative account usage fetched by the opt-in
    /// poller. Its reset timestamps and utilization feed the usage-window merge.
    public func ingestAccountUsage(_ usage: AccountUsage?) {
        accountUsage = usage
    }

    public func ingest(_ event: ClaudeCodeHookEvent) throws {
        guard event.schemaVersion == ClaudeCodeHookEvent.supportedSchemaVersion else {
            throw ClaudeCodeHookEventError.unsupportedSchema(event.schemaVersion)
        }
        guard !event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCodeHookEventError.invalidSession
        }
        if let existing = hookEventsBySession[event.sessionID], existing.sentAt > event.sentAt { return }
        hookEventsBySession[event.sessionID] = event
        pruneHookEvents()
    }

    public func ingest(_ event: ClaudeCodeStatusEvent) throws {
        guard event.schemaVersion == ClaudeCodeStatusEvent.supportedSchemaVersion else {
            throw ClaudeCodeHookEventError.unsupportedSchema(event.schemaVersion)
        }
        guard !event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCodeHookEventError.invalidSession
        }
        if let existing = statusEventsBySession[event.sessionID], existing.sentAt > event.sentAt { return }
        statusEventsBySession[event.sessionID] = event
        pruneStatusEvents()
    }

    public func snapshot() async throws -> ProviderSnapshot {
        pruneHookEvents()
        pruneStatusEvents()
        let files = sourceMode.usesLocalData ? recentTranscriptFiles() : []
        pruneSummaries(keeping: files)
        var sessionsByID: [String: AgentSession] = [:]

        // `files` is sorted newest-first. Two transcripts can carry the same
        // session ID (a resumed session copies its history before writing a
        // record with its own ID), so the first — freshest — file must win.
        for candidate in files {
            guard let session = parse(candidate), sessionsByID[session.id] == nil else { continue }
            sessionsByID[session.id] = session
        }

        // A SessionStart hook may arrive before Claude has flushed its JSONL.
        if sourceMode.usesRealtimeData {
            for event in hookEventsBySession.values where sessionsByID[event.sessionID] == nil {
                guard let session = normalizeHookOnly(event) else { continue }
                sessionsByID[event.sessionID] = session
            }
        }

        let sessions = sessionsByID.values.sortedWorkingFirst()

        let latestStatus = sourceMode.usesRealtimeData
            ? statusEventsBySession.values.max { $0.sentAt < $1.sentAt }
            : nil
        let latestUsageStatus = sourceMode.usesRealtimeData
            ? statusEventsBySession.values
                .filter { $0.fiveHour != nil || $0.sevenDay != nil }
                .max { $0.sentAt < $1.sentAt }
            : nil
        let hasLocalData = sourceMode.usesLocalData && fileManager.fileExists(atPath: projectsURL.path)
        let hasRealtimeData = sourceMode.usesRealtimeData
            && (!hookEventsBySession.isEmpty || latestStatus != nil)
        let localUsage = sourceMode.usesLocalData ? cachedPlanUsageSample() : nil
        let usageWindows = mergedUsageWindows(status: latestUsageStatus, local: localUsage)
        let hasProviderData = hasLocalData || hasRealtimeData
        return ProviderSnapshot(
            id: providerID,
            connectionState: hasProviderData ? .connected : .unavailable,
            sessions: sessions,
            usageWindows: usageWindows,
            updatedAt: max(
                sessions.map(\.lastActivityAt).max() ?? .distantPast,
                latestStatus.map { Date(millisecondsSince1970: $0.sentAt) } ?? .distantPast,
                localUsage?.measuredAt ?? .distantPast,
                now().addingTimeInterval(-relevantAge)
            )
        )
    }

    private struct UsageContribution {
        let utilization: Double
        let measuredAt: Date
        let resetsAt: Date?
    }

    /// Three sources feed the 5h/7d windows, each incomplete on its own:
    /// the status-line relay (has reset, terminal-only), Claude Desktop's local
    /// journal (no reset, but current whenever the app is used), and — when the
    /// user opts in — Anthropic's account endpoint (authoritative, has reset,
    /// no terminal needed). Per window, take the utilization from whichever
    /// source measured most recently and the reset from the freshest source
    /// that actually carries one.
    private func mergedUsageWindows(
        status: ClaudeCodeStatusEvent?,
        local: PlanUsageSample?
    ) -> [UsageWindow] {
        var byID: [String: [UsageContribution]] = [:]
        func add(_ id: String, _ utilization: Double, _ measuredAt: Date, _ resetsAt: Date?) {
            byID[id, default: []].append(
                UsageContribution(utilization: utilization, measuredAt: measuredAt, resetsAt: resetsAt)
            )
        }

        if let status {
            let at = Date(millisecondsSince1970: status.sentAt)
            if let window = status.fiveHour {
                add("claude-5h", window.usedPercentage / 100, at, window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            }
            if let window = status.sevenDay {
                add("claude-7d", window.usedPercentage / 100, at, window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            }
        }
        if let local {
            if let fiveHour = local.fiveHourFraction { add("claude-5h", fiveHour, local.measuredAt, nil) }
            if let sevenDay = local.sevenDayFraction { add("claude-7d", sevenDay, local.measuredAt, nil) }
        }
        if let account = freshAccountUsage() {
            if let window = account.fiveHour {
                add("claude-5h", window.utilizationFraction, account.fetchedAt, window.resetsAt)
            }
            if let window = account.sevenDay {
                add("claude-7d", window.utilizationFraction, account.fetchedAt, window.resetsAt)
            }
        }

        // Per-model weekly limits come only from the account endpoint; they
        // follow the two global windows, in the order the API lists them.
        var ordered: [(id: String, label: String)] = [
            ("claude-5h", "5 hours"),
            ("claude-7d", "7 days"),
        ]
        if let account = freshAccountUsage() {
            for scoped in account.scopedWeekly {
                let id = "claude-7d-\(scoped.id)"
                add(id, scoped.window.utilizationFraction, account.fetchedAt, scoped.window.resetsAt)
                // Labeled by model only: it sits right under the "7 days" bar,
                // so repeating the period would only add noise.
                ordered.append((id, scoped.label))
            }
        }
        return ordered.compactMap { meta in
            guard let contributions = byID[meta.id],
                  let freshest = contributions.max(by: { $0.measuredAt < $1.measuredAt })
            else { return nil }
            let resetsAt = contributions
                .filter { $0.resetsAt != nil }
                .max(by: { $0.measuredAt < $1.measuredAt })?
                .resetsAt
            return UsageWindow(
                id: meta.id,
                label: meta.label,
                usedFraction: freshest.utilization,
                resetsAt: resetsAt,
                measuredAt: freshest.measuredAt
            )
        }
    }

    private func freshAccountUsage() -> AccountUsage? {
        guard let accountUsage,
              accountUsage.fetchedAt >= now().addingTimeInterval(-relevantAge),
              accountUsage.fetchedAt <= now()
        else { return nil }
        return accountUsage
    }

    private func cachedPlanUsageSample() -> PlanUsageSample? {
        // FileManager attributes, NOT URL.resourceValues: Foundation caches
        // resource values on a long-lived URL, so a connector polling the same
        // URL instance kept seeing a stale modification date and never
        // invalidated this cache — the menu then showed day-old percentages
        // while the journal on disk was minutes fresh.
        guard let attributes = try? fileManager.attributesOfItem(atPath: planUsageHistoryURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let fileSize = (attributes[.size] as? NSNumber)?.intValue
        else {
            cachedPlanUsage = nil
            return nil
        }
        let sample: PlanUsageSample?
        if let cached = cachedPlanUsage, cached.modifiedAt == modifiedAt, cached.fileSize == fileSize {
            sample = cached.sample
        } else {
            planUsageDecodeCount += 1
            sample = PlanUsageHistoryReader.latestSample(at: planUsageHistoryURL)
            cachedPlanUsage = CachedPlanUsage(modifiedAt: modifiedAt, fileSize: fileSize, sample: sample)
        }
        // Ignore a journal that has not been touched in a long time so the UI
        // never presents week-old percentages as current, and one dated in the
        // future, which cannot describe usage measured before now.
        guard let sample,
              sample.measuredAt >= now().addingTimeInterval(-relevantAge),
              sample.measuredAt <= now()
        else { return nil }
        return sample
    }

    private func recentTranscriptFiles() -> [ClaudeTranscriptCandidate] {
        guard let enumerator = fileManager.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now().addingTimeInterval(-relevantAge)
        var candidates: [ClaudeTranscriptCandidate] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Claude stores subagent transcripts below <session>/subagents.
            // Their cache usage belongs to the parent but they are not top-level sessions.
            guard !url.pathComponents.contains("subagents"),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize, fileSize > 100,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff
            else { continue }
            candidates.append(ClaudeTranscriptCandidate(url: url, modifiedAt: modifiedAt, fileSize: fileSize))
        }
        return candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(50).map { $0 }
    }

    private func parse(_ candidate: ClaudeTranscriptCandidate) -> AgentSession? {
        guard let summary = summarizeReusingCache(candidate) else { return nil }

        let sessionID = summary.sessionID
        let directory = summary.cwd.map { URL(fileURLWithPath: $0) }
        let hook = sourceMode.usesRealtimeData ? hookEventsBySession[sessionID] : nil
        let statusEvent = sourceMode.usesRealtimeData ? statusEventsBySession[sessionID] : nil
        let transcriptActivity = [summary.latestUserAt, summary.latestAssistantAt, summary.latestTurnEndedAt]
            .compactMap { $0 }.max() ?? candidate.modifiedAt
        let hookActivity = hook.map { Date(millisecondsSince1970: $0.sentAt) }
        let activityAt = max(transcriptActivity, hookActivity ?? .distantPast)
        let inferred = inferredStatus(
            latestUserAt: summary.latestUserAt,
            latestAssistantAt: summary.latestAssistantAt,
            latestTurnEndedAt: summary.latestTurnEndedAt,
            activityAt: activityAt
        )
        let status: SessionStatus
        if let hook, let hookActivity, hookActivity >= transcriptActivity.addingTimeInterval(-2) {
            status = statusFromHook(hook)
        } else {
            status = inferred
        }
        let cache = makeCache(summary.latestUsage)

        return AgentSession(
            id: sessionID,
            providerID: providerID,
            title: summary.title.flatMap(Self.sanitizedTitle)
                ?? directory.map { "Claude Code · \($0.lastPathComponent)" }
                ?? "Claude Code session",
            projectName: directory?.lastPathComponent,
            model: hook?.model ?? statusEvent?.model ?? summary.model,
            status: status,
            lastActivityAt: activityAt,
            cache: cache,
            cacheHealth: summary.evidence.snapshot(measuredAt: activityAt),
            target: SessionTarget(
                providerID: providerID,
                sessionID: sessionID,
                workingDirectory: directory
            )
        )
    }

    private func summarizeReusingCache(_ candidate: ClaudeTranscriptCandidate) -> ClaudeTranscriptSummary? {
        if let cached = summariesByPath[candidate.url.path],
           cached.modifiedAt == candidate.modifiedAt,
           cached.fileSize == candidate.fileSize {
            return cached.summary
        }
        let summary = summarize(candidate)
        summariesByPath[candidate.url.path] = CachedTranscriptSummary(
            modifiedAt: candidate.modifiedAt,
            fileSize: candidate.fileSize,
            summary: summary
        )
        return summary
    }

    private func pruneSummaries(keeping candidates: [ClaudeTranscriptCandidate]) {
        let livePaths = Set(candidates.map(\.url.path))
        summariesByPath = summariesByPath.filter { livePaths.contains($0.key) }
    }

    /// Folds the transcript into facts that depend only on the file contents,
    /// never on the clock or live hook state, so the result stays valid for
    /// as long as the file itself is unchanged.
    private func summarize(_ candidate: ClaudeTranscriptCandidate) -> ClaudeTranscriptSummary? {
        transcriptDecodeCount += 1
        let records = BoundedJSONLReader.decode(ClaudeTranscriptRecord.self, from: candidate.url)
        guard !records.isEmpty else { return nil }

        var sessionID = candidate.url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var title: String?
        var model: String?
        var latestUserAt: Date?
        var latestAssistantAt: Date?
        var latestTurnEndedAt: Date?
        var latestUsage: ClaudeUsageObservation?
        var evidence = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .previousTurn, tokenTotals: .whenObserved)
        )
        var seenAssistantObservations: Set<String> = []

        for record in records {
            if let value = record.sessionID, !value.isEmpty { sessionID = value }
            cwd = record.cwd ?? cwd
            title = record.aiTitle ?? title
            let timestamp = record.timestamp.flatMap(Self.parseDate)

            switch record.type {
            case "user", "human":
                if let timestamp { latestUserAt = max(latestUserAt ?? .distantPast, timestamp) }
            case "assistant":
                model = record.message?.model ?? model
                guard let timestamp else { continue }
                latestAssistantAt = max(latestAssistantAt ?? .distantPast, timestamp)
                guard let usage = record.message?.usage else { continue }
                let key: String
                if let messageID = record.message?.id, !messageID.isEmpty {
                    key = "\(messageID)|\(record.requestID ?? "")"
                } else {
                    key = "\(timestamp.timeIntervalSince1970)-\(usage.inputTokens ?? 0)-\(usage.cacheReadInputTokens ?? 0)-\(usage.cacheCreationInputTokens ?? 0)"
                }
                guard seenAssistantObservations.insert(key).inserted else { continue }
                let observation = ClaudeUsageObservation(timestamp: timestamp, usage: usage)
                if latestUsage == nil || timestamp >= latestUsage!.timestamp { latestUsage = observation }
                evidence.observe(Self.evidenceObservation(for: observation))
            case "system" where record.subtype == "turn_duration":
                if let timestamp { latestTurnEndedAt = max(latestTurnEndedAt ?? .distantPast, timestamp) }
            default:
                continue
            }
        }

        return ClaudeTranscriptSummary(
            sessionID: sessionID,
            cwd: cwd,
            title: title,
            model: model,
            latestUserAt: latestUserAt,
            latestAssistantAt: latestAssistantAt,
            latestTurnEndedAt: latestTurnEndedAt,
            latestUsage: latestUsage,
            evidence: evidence
        )
    }

    private func normalizeHookOnly(_ event: ClaudeCodeHookEvent) -> AgentSession? {
        let activityAt = Date(millisecondsSince1970: event.sentAt)
        let status = statusFromHook(event)
        guard status == .working || status.requiresAttention else { return nil }
        let directory = event.workingDirectory.map { URL(fileURLWithPath: $0) }
        return AgentSession(
            id: event.sessionID,
            providerID: providerID,
            title: directory.map { "Claude Code · \($0.lastPathComponent)" } ?? "Claude Code session",
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

    private func statusFromHook(_ event: ClaudeCodeHookEvent) -> SessionStatus {
        let activityAt = Date(millisecondsSince1970: event.sentAt)
        switch event.eventName {
        case "UserPromptSubmit", "SessionStart":
            return now().timeIntervalSince(activityAt) >= stuckAfter ? .stuck : .working
        case "PermissionRequest":
            return .waitingForApproval
        case "Notification":
            return event.notificationType == "permission_prompt" ? .waitingForApproval : .waitingForInput
        case "Stop":
            return .idle
        case "StopFailure":
            return .failed
        case "SessionEnd":
            return .completed
        default:
            return .idle
        }
    }

    private func inferredStatus(
        latestUserAt: Date?,
        latestAssistantAt: Date?,
        latestTurnEndedAt: Date?,
        activityAt: Date
    ) -> SessionStatus {
        // Local transcripts are history, not proof that a Claude process is
        // still alive. Keep a short diagnostic window for an unanswered prompt,
        // then let it return to idle unless a fresh live hook says otherwise.
        guard now().timeIntervalSince(activityAt) < hookFreshness else {
            return .idle
        }
        if let latestUserAt, latestUserAt > (latestAssistantAt ?? .distantPast),
           latestUserAt > (latestTurnEndedAt ?? .distantPast) {
            return now().timeIntervalSince(activityAt) >= stuckAfter ? .stuck : .working
        }
        return .idle
    }

    private func makeCache(_ observation: ClaudeUsageObservation?) -> CacheSnapshot {
        guard let observation else { return .unknown }
        let usage = observation.usage
        let explicitOneHour = usage.cacheCreation?.ephemeral1hInputTokens ?? 0 > 0
        let explicitFiveMinutes = usage.cacheCreation?.ephemeral5mInputTokens ?? 0 > 0
        let ttl = explicitOneHour ? 3_600 : 300
        let age = max(0, Int(now().timeIntervalSince(observation.timestamp)))
        let remaining = max(0, ttl - age)
        let cached = max(0, usage.cacheReadInputTokens ?? 0)
        let written = max(0, usage.cacheCreationInputTokens ?? 0)
        let temperature: CacheTemperature
        if remaining == 0 {
            temperature = .cold
        } else if remaining <= 60 {
            temperature = .expiring
        } else {
            temperature = .warm
        }
        return CacheSnapshot(
            temperature: temperature,
            remainingSeconds: remaining,
            ttlSeconds: ttl,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cachedReadTokens: cached,
            cacheWriteTokens: written,
            lastConfirmedAt: cached > 0 || written > 0 ? observation.timestamp : nil,
            confidence: explicitOneHour || explicitFiveMinutes ? .exactPolicy : .inferred,
            reason: explicitOneHour || explicitFiveMinutes
                ? "Claude Code transcript cache telemetry with observed TTL bucket"
                : "Claude Code transcript cache telemetry; five-minute TTL fallback"
        )
    }

    private func pruneHookEvents() {
        let cutoffMilliseconds = Int64(now().addingTimeInterval(-hookFreshness).timeIntervalSince1970 * 1_000)
        hookEventsBySession = hookEventsBySession.filter { $0.value.sentAt >= cutoffMilliseconds }
    }

    private func pruneStatusEvents() {
        let cutoffMilliseconds = Int64(now().addingTimeInterval(-relevantAge).timeIntervalSince1970 * 1_000)
        statusEventsBySession = statusEventsBySession.filter { $0.value.sentAt >= cutoffMilliseconds }
    }
}
