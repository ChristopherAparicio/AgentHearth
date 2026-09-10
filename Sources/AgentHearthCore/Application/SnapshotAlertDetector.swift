import AgentHearthDomain
import Foundation

public actor SnapshotAlertDetector {
    /// How long a session that vanished from the snapshots keeps its last known
    /// state as a comparison baseline. A transient connector failure (one
    /// failed SSH poll) makes every remote session disappear for a cycle; when
    /// it comes back, comparing against its pre-failure state is what lets an
    /// approval request that happened during the gap still alert, and what
    /// keeps a cache already inside the warning window from alerting again as
    /// if freshly discovered. Kept short — a few poll cycles plus the maximum
    /// SSH backoff — so a host re-enabled much later does not replay stale
    /// "Agent finished" transitions from before it was disabled.
    static let disappearedSessionRetention: TimeInterval = 5 * 60

    private struct RememberedSession {
        let session: AgentSession
        let lastSeenAt: Date
    }

    private var previousSessions: [String: RememberedSession] = [:]
    /// Recent readings per usage window, newest last. A series rather than a
    /// single previous value: the burn rule asks how much a window lost over
    /// the last few minutes, which spans several polls.
    private var usageSamples: [String: [UsageBurnSample]] = [:]
    /// When each session was first *observed* working in its current spell.
    /// Not when the turn began — polling only sees the session once a cycle —
    /// so the figure is a floor. A burst attributed to a session that has been
    /// working without pause is the signature of a runaway loop, which is
    /// worth saying in the alert.
    private var workingSince: [String: Date] = [:]
    private var hasBaseline = false
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func detect(
        in snapshots: [ProviderSnapshot],
        preferences: AlertPreferences,
        focus: SessionFocusPreferences = SessionFocusPreferences()
    ) -> [AgentAlert] {
        // Keys are normally unique per provider; duplicates would come from an
        // unmerged snapshot list and must not trap the app.
        let currentSessions = Dictionary(
            snapshots.flatMap(\.sessions).map { (sessionKey($0), $0) },
            uniquingKeysWith: { first, second in
                first.lastActivityAt >= second.lastActivityAt ? first : second
            }
        )
        let burnLookback = TimeInterval(preferences.usageBurnMinutes * 60)

        guard hasBaseline else {
            remember(currentSessions)
            recordUsage(in: snapshots, lookback: burnLookback)
            hasBaseline = true
            guard preferences.notificationsEnabled else { return [] }
            return currentSessions.values.compactMap { session in
                guard allowsSessionAlerts(for: session, focus: focus) else { return nil }
                return initialCacheAlert(for: session, preferences: preferences)
            }
        }

        guard preferences.notificationsEnabled else {
            remember(currentSessions)
            recordUsage(in: snapshots, lookback: burnLookback)
            collapseUsageSeries()
            return []
        }

        var alerts: [AgentAlert] = []
        for (key, session) in currentSessions {
            let previous = previousSessions[key]?.session
            if allowsSessionAlerts(for: session, focus: focus) {
                if let previous {
                    if preferences.sessionAttentionEnabled,
                       previous.status != session.status,
                       let alert = attentionAlert(for: session) {
                        alerts.append(alert)
                    }
                    if preferences.sessionCompletionEnabled,
                       previous.status == .working,
                       session.status == .idle || session.status == .completed {
                        alerts.append(completionAlert(for: session))
                    }
                    if preferences.shouldNotifyCacheExpiry(for: session),
                       crossedCacheWarning(
                        from: previous.cache,
                        to: session.cache,
                        threshold: preferences.cacheWarningSeconds(for: session)
                       ) {
                        alerts.append(cacheAlert(for: session))
                    }
                } else if let alert = initialCacheAlert(for: session, preferences: preferences) {
                    alerts.append(alert)
                }
            }
            if shouldAskToPromote(session, previous: previous, focus: focus) {
                alerts.append(promoteAlert(for: session))
            }
        }

        if preferences.usageLimitEnabled {
            for snapshot in snapshots {
                for window in snapshot.usageWindows {
                    let key = usageKey(providerID: snapshot.id, windowID: window.id)
                    guard let previous = usageSamples[key]?.last?.fraction,
                          let threshold = preferences.usageThresholdCrossed(
                            from: previous,
                            to: window.usedFraction
                          )
                    else { continue }
                    alerts.append(usageAlert(providerID: snapshot.id, window: window, threshold: threshold))
                }
            }
        }

        // The burn rule reads the series including this cycle's reading, so it
        // runs after recording, unlike the threshold rule above which compares
        // against the previous one.
        recordUsage(in: snapshots, lookback: burnLookback)
        if preferences.usageBurnEnabled {
            alerts.append(contentsOf: burnAlerts(in: snapshots, preferences: preferences))
        } else {
            collapseUsageSeries()
        }

        remember(currentSessions)
        return alerts
    }

    /// Replaces the baseline with the current sessions while carrying forward
    /// recently disappeared ones (see `disappearedSessionRetention`).
    private func remember(_ current: [String: AgentSession]) {
        let timestamp = now()
        var next = current.mapValues { RememberedSession(session: $0, lastSeenAt: timestamp) }
        for (key, remembered) in previousSessions
        where next[key] == nil
            && timestamp.timeIntervalSince(remembered.lastSeenAt) < Self.disappearedSessionRetention {
            next[key] = remembered
        }
        previousSessions = next

        // Only sessions still working carry a start forward; anything that
        // stopped, finished, or vanished loses it, so the next spell of work
        // is timed from its own beginning.
        var stillWorking: [String: Date] = [:]
        for (key, session) in current where session.status == .working {
            stillWorking[key] = workingSince[key] ?? timestamp
        }
        workingSince = stillWorking
    }

    /// Adds this cycle's reading of every usage window to its series.
    private func recordUsage(in snapshots: [ProviderSnapshot], lookback: TimeInterval) {
        for snapshot in snapshots {
            for window in snapshot.usageWindows {
                let key = usageKey(providerID: snapshot.id, windowID: window.id)
                let sample = UsageBurnSample(fraction: window.usedFraction, measuredAt: window.measuredAt)
                usageSamples[key] = UsageBurnPolicy.appending(
                    sample,
                    to: usageSamples[key] ?? [],
                    lookback: lookback
                )
            }
        }
    }

    /// Drops every reading but the newest of each window.
    ///
    /// Used on the paths that record without evaluating — notifications off,
    /// or the burn rule itself off. Those cycles must still advance the
    /// baseline, but the rise they observed has gone unreported, and firing it
    /// the moment the user switches alerts back on would deliver a burst that
    /// is by then minutes or hours old.
    private func collapseUsageSeries() {
        usageSamples = usageSamples.compactMapValues { samples in
            samples.isEmpty ? nil : Array(samples.suffix(1))
        }
    }

    private func burnAlerts(in snapshots: [ProviderSnapshot], preferences: AlertPreferences) -> [AgentAlert] {
        var alerts: [AgentAlert] = []
        for snapshot in snapshots {
            for window in snapshot.usageWindows {
                let key = usageKey(providerID: snapshot.id, windowID: window.id)
                guard let samples = usageSamples[key],
                      let burn = UsageBurnPolicy.burn(in: samples, points: preferences.usageBurnPoints)
                else { continue }
                // Reported: restart the series from the newest reading. A
                // cooldown would re-alert on the same burst once it lapsed;
                // restarting means the next alert needs a genuinely new rise.
                usageSamples[key] = Array(samples.suffix(1))
                alerts.append(burnAlert(
                    providerID: snapshot.id,
                    window: window,
                    burn: burn,
                    sessions: snapshot.sessions
                ))
            }
        }
        return alerts
    }

    private func burnAlert(
        providerID: AgentProviderID,
        window: UsageWindow,
        burn: UsageBurn,
        sessions: [AgentSession]
    ) -> AgentAlert {
        let burstStart = window.measuredAt.addingTimeInterval(-burn.elapsed)
        let suspect = topSuspect(among: sessions, providerID: providerID, since: burstStart)
        var summary = "\(providerID.rawValue) · \(window.label) +\(burn.gainedPoints)% of window in \(minutesText(burn.elapsed))"
        if let suspect {
            summary += " — \(suspectText(suspect))"
        }
        if let remaining = burn.minutesToExhaustion {
            summary += " · empty in ~\(minutesText(remaining * 60)) at this rate"
        }
        return AgentAlert(
            id: UUID().uuidString,
            sourceID: .agentHearth,
            type: "usage.burn",
            severity: (burn.minutesToExhaustion ?? .greatestFiniteMagnitude) < 30 ? .error : .warning,
            title: "Usage burning fast",
            summary: summary,
            sessionTarget: suspect?.target,
            fingerprint: "\(providerID.rawValue):\(window.id):usage-burn:\(burn.gainedPoints)"
        )
    }

    /// The session most likely behind a burst: the costliest last turn among
    /// this provider's sessions that were active during it.
    ///
    /// This is a ranking, not a proof. With several agents running
    /// concurrently nothing in the provider's counters says which one moved
    /// the account-wide window, so the alert names a likely culprit and the
    /// consumption view shows the full list.
    private func topSuspect(
        among sessions: [AgentSession],
        providerID: AgentProviderID,
        since burstStart: Date
    ) -> AgentSession? {
        sessions
            .filter { $0.providerID == providerID }
            .filter { $0.status == .working || $0.lastActivityAt >= burstStart }
            .filter { turnCost($0) > 0 }
            .max { turnCost($0) < turnCost($1) }
    }

    /// What a session's last measured turn plausibly cost the window. Cached
    /// reads are excluded: they are far cheaper than fresh input, so counting
    /// them would rank a large warm session above a smaller one that is
    /// genuinely reprocessing its whole context every turn.
    private func turnCost(_ session: AgentSession) -> Int {
        (session.cache.uncachedInputTokens ?? 0) + max(0, session.cache.outputTokens ?? 0)
    }

    private func suspectText(_ session: AgentSession) -> String {
        let name = session.projectName ?? session.title
        guard let since = workingSince[sessionKey(session)] else { return name }
        let elapsed = now().timeIntervalSince(since)
        // Below a minute the duration says nothing a reader can act on.
        guard elapsed >= 60 else { return name }
        return "\(name), working \(minutesText(elapsed))"
    }

    private func minutesText(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        return "\(minutes) min"
    }

    /// Session-scoped alerts (attention, completion, cache expiry) narrow to
    /// pinned sessions in priority-only mode. Usage-limit alerts are
    /// account-wide and are never filtered here.
    private func allowsSessionAlerts(
        for session: AgentSession,
        focus: SessionFocusPreferences
    ) -> Bool {
        focus.mode == .all || focus.isPinned(session)
    }

    /// The promotion ask fires for an unpinned, active session in
    /// priority-only mode — either brand new this cycle, or transitioning back
    /// to activity from a terminal status. Requiring an actual status change
    /// on the transition path keeps a persistently failed session from asking
    /// again every cycle.
    private func shouldAskToPromote(
        _ session: AgentSession,
        previous: AgentSession?,
        focus: SessionFocusPreferences
    ) -> Bool {
        guard focus.mode == .priorityOnly,
              focus.askOnNewSession,
              !focus.isPinned(session),
              session.status == .working || session.status.requiresAttention
        else { return false }
        guard let previous else { return true }
        return (previous.status == .completed || previous.status == .failed)
            && previous.status != session.status
    }

    private func promoteAlert(for session: AgentSession) -> AgentAlert {
        AgentAlert(
            id: UUID().uuidString,
            sourceID: .agentHearth,
            type: "session.promote",
            severity: .information,
            title: "New session started",
            summary: "\(session.projectName ?? session.title) — prioritize it to focus notifications?",
            sessionTarget: session.target,
            fingerprint: "\(session.providerID.rawValue):\(session.host.id):\(session.id):promote-ask"
        )
    }

    private func attentionAlert(for session: AgentSession) -> AgentAlert? {
        let severity: AlertSeverity
        let title: String
        switch session.status {
        case .waitingForApproval:
            severity = .warning
            title = "Approval required"
        case .waitingForInput:
            severity = .information
            title = "Agent is waiting"
        case .stuck:
            severity = .error
            title = "Session may be stuck"
        case .failed:
            severity = .error
            title = "Session failed"
        case .working, .idle, .completed:
            return nil
        }
        return AgentAlert(
            id: UUID().uuidString,
            sourceID: .agentHearth,
            type: "session.\(session.status.rawValue)",
            severity: severity,
            title: title,
            summary: session.title,
            sessionTarget: session.target,
            fingerprint: "\(session.providerID.rawValue):\(session.id):\(session.status.rawValue)"
        )
    }

    private func completionAlert(for session: AgentSession) -> AgentAlert {
        return AgentAlert(
            id: UUID().uuidString,
            sourceID: .agentHearth,
            type: "session.completed",
            severity: .information,
            title: "Agent finished",
            summary: session.title,
            sessionTarget: session.target,
            fingerprint: "\(session.providerID.rawValue):\(session.id):completed"
        )
    }

    private func cacheAlert(for session: AgentSession) -> AgentAlert {
        let remaining = max(0, session.cache.remainingSeconds ?? 0)
        let countdown = String(format: "%d:%02d", remaining / 60, remaining % 60)
        return AgentAlert(
            id: UUID().uuidString,
            sourceID: .agentHearth,
            type: "cache.expiring",
            severity: .warning,
            title: "Prompt cache expiring",
            summary: "\(session.title) · \(session.host.displayName) · \(countdown) remaining",
            sessionTarget: session.target,
            fingerprint: "\(session.providerID.rawValue):\(session.host.id):\(session.id):cache-expiring"
        )
    }

    private func usageAlert(
        providerID: AgentProviderID,
        window: UsageWindow,
        threshold: UsageAlertThreshold
    ) -> AgentAlert {
        AgentAlert(
            id: UUID().uuidString,
            sourceID: .agentHearth,
            type: "usage.limit",
            severity: threshold.percentage >= 95 ? .error : .warning,
            title: "Usage limit warning",
            summary: "\(providerID.rawValue) · \(window.label) at \(Int(window.usedFraction * 100))%",
            fingerprint: "\(providerID.rawValue):\(window.id):usage-\(threshold.percentage)",
            soundName: threshold.soundName
        )
    }

    private func initialCacheAlert(
        for session: AgentSession,
        preferences: AlertPreferences
    ) -> AgentAlert? {
        guard preferences.shouldNotifyCacheExpiry(for: session),
              isWithinCacheWarning(session.cache, threshold: preferences.cacheWarningSeconds(for: session))
        else { return nil }
        return cacheAlert(for: session)
    }

    private func crossedCacheWarning(
        from previous: CacheSnapshot,
        to current: CacheSnapshot,
        threshold: Int
    ) -> Bool {
        guard isWithinCacheWarning(current, threshold: threshold)
        else { return false }
        // A cache we could not time before (no countdown yet, or a cold/unknown
        // reading) has just become measurable inside the window: warn once now,
        // since the countdown only ever shrinks from here.
        guard let previousRemaining = previous.remainingSeconds else {
            return true
        }
        return previousRemaining > threshold
    }

    /// The warning is driven by the countdown alone. Connectors only flag
    /// `.expiring` during the last 60 seconds, so gating on that temperature
    /// made every configured lead time above one minute unreachable: the
    /// countdown had already crossed the threshold while still `.warm`.
    private func isWithinCacheWarning(_ cache: CacheSnapshot, threshold: Int) -> Bool {
        guard cache.temperature == .warm || cache.temperature == .expiring,
              let remaining = cache.remainingSeconds
        else { return false }
        return remaining > 0 && remaining <= threshold
    }

    private func sessionKey(_ session: AgentSession) -> String {
        "\(session.providerID.rawValue):\(session.host.id):\(session.id)"
    }

    private func usageKey(providerID: AgentProviderID, windowID: String) -> String {
        "\(providerID.rawValue):\(windowID)"
    }
}
