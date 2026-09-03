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
    private var previousUsage: [String: Double] = [:]
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
        let currentUsage = Dictionary(
            snapshots.flatMap { snapshot in
                snapshot.usageWindows.map { (usageKey(providerID: snapshot.id, windowID: $0.id), $0.usedFraction) }
            },
            uniquingKeysWith: { _, second in second }
        )

        guard hasBaseline else {
            remember(currentSessions)
            previousUsage = currentUsage
            hasBaseline = true
            guard preferences.notificationsEnabled else { return [] }
            return currentSessions.values.compactMap { session in
                guard allowsSessionAlerts(for: session, focus: focus) else { return nil }
                return initialCacheAlert(for: session, preferences: preferences)
            }
        }

        guard preferences.notificationsEnabled else {
            remember(currentSessions)
            previousUsage = currentUsage
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
                    guard let previous = previousUsage[key],
                          let threshold = preferences.usageThresholdCrossed(
                            from: previous,
                            to: window.usedFraction
                          )
                    else { continue }
                    alerts.append(usageAlert(providerID: snapshot.id, window: window, threshold: threshold))
                }
            }
        }

        remember(currentSessions)
        previousUsage = currentUsage
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
