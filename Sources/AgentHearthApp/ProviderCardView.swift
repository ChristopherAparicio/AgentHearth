import AgentHearthCore
import SwiftUI

struct ProviderCardView: View {
    let snapshot: ProviderSnapshot
    let onOpenSession: (SessionTarget) -> Void
    var openSessionHelp: (SessionTarget) -> String = { _ in "Resume in Terminal" }
    let cacheAlertDisposition: (AgentSession) -> CacheAlertDisposition?
    let cacheNotificationsEnabled: (AgentSession) -> Bool
    let hasSessionRule: (AgentSession) -> Bool
    let onAcknowledgeCache: (AgentSession) -> Void
    let onIgnoreCache: (AgentSession) -> Void
    let onSetSessionNotificationsEnabled: (Bool, AgentSession) -> Void
    let onClearSessionRule: (AgentSession) -> Void
    var isPinned: (AgentSession) -> Bool = { _ in false }
    var onTogglePin: ((AgentSession) -> Void)?
    let showsCacheIcon: Bool
    let showsCacheCountdown: Bool
    let showsCacheHits: Bool
    var cacheReuseDisplayMode: CacheReuseDisplayMode = .sessionGlobal
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 11)

            if !snapshot.usageWindows.isEmpty {
                // TimelineView re-renders each minute so reset countdowns and the
                // measured-ago note tick down live instead of only on a poll.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(snapshot.usageWindows) { window in
                            usageRow(window, now: context.date)
                        }
                        usageMeasuredNote(now: context.date)
                    }
                }
            }

            if !snapshot.usageWindows.isEmpty, !snapshot.sessions.isEmpty {
                Divider()
                    .padding(.vertical, 11)
            }

            if !snapshot.sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 {
                            Divider()
                                .padding(.leading, compact ? 26 : 35)
                        }
                        sessionRow(session)
                            .padding(.vertical, compact ? 4 : 8)
                    }
                }
                .padding(.vertical, -8)
            } else if snapshot.usageWindows.isEmpty {
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 9)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.quaternary.opacity(0.42))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.055), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: snapshot.id.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(snapshot.id.tint)
                .frame(width: 28, height: 28)
                .background(snapshot.id.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.id.displayName)
                    .font(.subheadline.weight(.semibold))
                Text(activityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(sessionCountLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.8), in: Capsule())
        }
    }

    private func usageRow(_ window: UsageWindow, now: Date) -> some View {
        // Label, bar, and percentage share one line to save vertical space.
        // A fixed-width label keeps every bar left-aligned across rows.
        HStack(spacing: 8) {
            Text(window.label)
                .font(.caption.weight(.medium))
                .frame(width: 48, alignment: .leading)

            ProgressView(value: window.usedFraction)
                .progressViewStyle(.linear)
                .tint(usageColor(window.usedFraction))

            // Fixed-width columns so the percentage and the reset countdown line
            // up across the 5h and 7d rows even when one row lacks a reset.
            Text(window.usedFraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(usageColor(window.usedFraction))
                .frame(width: 40, alignment: .trailing)

            Group {
                if let resetsAt = window.resetsAt, let countdown = CompactDuration.until(resetsAt, now: now) {
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                            .font(.system(size: 8))
                        Text(countdown.text)
                    }
                    .foregroundStyle(.secondary)
                    .help("\(window.label) resets in \(countdown.text)")
                }
            }
            .font(.caption2)
            .frame(width: 58, alignment: .trailing)
        }
    }

    // A single data-freshness note shown only when NO window has a reset time
    // (usage read from Claude Desktop's journal, which records none). Shown once
    // per card — not per window — so it never reads like a per-window reset.
    @ViewBuilder
    private func usageMeasuredNote(now: Date) -> some View {
        let windows = snapshot.usageWindows
        if windows.allSatisfy({ $0.resetsAt == nil }),
           let measuredAt = windows.map(\.measuredAt).max(),
           now.timeIntervalSince(measuredAt) >= 60 {
            let age = CompactDuration(now.timeIntervalSince(measuredAt))
            Label("Measured \(age.text) ago", systemImage: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("Reset times appear once a terminal session reports them")
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(session.status.tint.opacity(0.14))
                Circle()
                    .fill(session.status.tint)
                    .frame(width: 7, height: 7)
            }
            .frame(width: compact ? 18 : 26, height: compact ? 18 : 26)
            // A badge appears only when the status asks something of the user
            // (attention or an outcome); for Working and Idle the dot's color
            // is the whole story, so it carries the VoiceOver label itself.
            .accessibilityHidden(Self.showsStatusBadge(session.status))
            .accessibilityLabel(session.status.label)
            .help(session.status.label)

            if compact {
                compactSessionContent(session)
            } else {
                comfortableSessionContent(session)
            }

            Spacer(minLength: 4)

            if let onTogglePin {
                let pinned = isPinned(session)
                Button {
                    onTogglePin(session)
                } label: {
                    Image(systemName: pinned ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: compact ? 20 : 25, height: compact ? 20 : 25)
                        .background(.quaternary.opacity(0.75), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(pinned ? Color.yellow : Color.secondary)
                .help(pinned ? "Remove from priority sessions" : "Mark as a priority session")
            }

            // Sessions without a live cache keep a dimmed bell whose menu
            // carries only the standing per-session notification switches, so
            // notifications can be prepared before re-engaging the session.
            CacheAlertMenu(
                session: session,
                hasActiveCache: session.cache.temperature == .warm
                    || session.cache.temperature == .expiring,
                disposition: cacheAlertDisposition(session),
                notificationsEnabled: cacheNotificationsEnabled(session),
                hasSessionRule: hasSessionRule(session),
                onAcknowledge: onAcknowledgeCache,
                onIgnoreCurrentCache: onIgnoreCache,
                onSetSessionNotificationsEnabled: onSetSessionNotificationsEnabled,
                onClearSessionRule: onClearSessionRule
            )

            if let target = session.target {
                Button {
                    onOpenSession(target)
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: compact ? 20 : 25, height: compact ? 20 : 25)
                        .background(.quaternary.opacity(0.75), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(openSessionHelp(target))
            } else {
                Color.clear.frame(width: compact ? 20 : 25, height: compact ? 20 : 25)
            }
        }
    }

    private func comfortableSessionContent(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if isPinned(session) {
                    pinnedIndicator
                }

                Text(session.titleWithoutProviderPrefix)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if Self.showsStatusBadge(session.status) {
                    statusBadge(session.status)
                }
            }

            HStack(spacing: 7) {
                if let source = session.source {
                    Label(source.displayName, systemImage: "server.rack")
                        .foregroundStyle(.cyan)
                }
                if session.host.kind == .ssh {
                    Label(session.host.displayName, systemImage: "network")
                        .foregroundStyle(.cyan)
                }
                if let projectName = session.projectName {
                    Label(projectName, systemImage: "folder")
                }
                if showsCacheIcon {
                    cacheStatus(session.cache)
                }
                if showsCacheHits, let cache = cacheReuseLabel(session, prefix: "Cache ") {
                    Label(cache.text, systemImage: "chart.bar.fill")
                        .foregroundStyle(cache.color)
                        .help(cache.help)
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // Reuse across ALL of a session's turns (cold starts included), not just the
    // last turn — a session that cold-started often reads low even if its latest
    // turn hit the cache.
    private func sessionReuseRate(_ session: AgentSession) -> Double? {
        session.cacheHealth?.tokenReuseRate ?? session.cache.cacheReuseRate
    }

    /// Builds the cache-reuse label honoring the chosen display mode: the whole
    /// session, the last turn, or both. Colored by whichever value it leads with.
    private func cacheReuseLabel(_ session: AgentSession, prefix: String) -> (text: String, color: Color, help: String)? {
        func pct(_ v: Double) -> Int { Int((v * 100).rounded()) }
        let global = sessionReuseRate(session)
        let last = session.cache.cacheReuseRate

        switch cacheReuseDisplayMode {
        case .sessionGlobal:
            guard let global else { return nil }
            return ("\(prefix)\(pct(global))%", reuseColor(global), "Cache reuse across the whole session")
        case .lastTurn:
            guard let last else { return nil }
            return ("\(prefix)\(pct(last))%", reuseColor(last), "Cache reuse on the latest turn")
        case .both:
            guard let global else {
                guard let last else { return nil }
                return ("\(prefix)\(pct(last))%", reuseColor(last), "Cache reuse on the latest turn")
            }
            let lastText = last.map { " · last \(pct($0))%" } ?? ""
            return ("\(prefix)\(pct(global))%\(lastText)", reuseColor(global), "Whole session · latest turn")
        }
    }

    // A single dense line: title, status, and (space permitting) the SSH host
    // and cache countdown fold inline instead of onto a second row.
    private func compactSessionContent(_ session: AgentSession) -> some View {
        HStack(spacing: 6) {
            if isPinned(session) {
                pinnedIndicator
            }

            Text(session.titleWithoutProviderPrefix)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            if Self.showsStatusBadge(session.status) {
                statusBadge(session.status)
            }

            if session.host.kind == .ssh {
                Image(systemName: "network")
                    .font(.system(size: 9))
                    .foregroundStyle(.cyan)
            }

            if showsCacheIcon, let duration = session.cache.compactDurationText, showsCacheCountdown {
                Label(duration, systemImage: cacheSymbol(session.cache.temperature))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if showsCacheHits, let cache = cacheReuseLabel(session, prefix: "") {
                Label(cache.text, systemImage: "chart.bar.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(cache.color)
                    .lineLimit(1)
                    .fixedSize()
                    .help(cache.help)
            }
        }
    }

    private var pinnedIndicator: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.yellow)
            .accessibilityLabel("Priority session")
            .help("Priority session")
    }

    /// Working and Idle are the quiet states the dot color fully conveys; a
    /// badge is reserved for statuses that need the user (attention states)
    /// or announce an outcome (completed).
    static func showsStatusBadge(_ status: SessionStatus) -> Bool {
        status.requiresAttention || status == .completed
    }

    private func statusBadge(_ status: SessionStatus) -> some View {
        Text(status.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(status.tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.11), in: Capsule())
    }

    @ViewBuilder
    private func cacheStatus(_ cache: CacheSnapshot) -> some View {
        if showsCacheCountdown, let duration = cache.compactDurationText {
            Label(duration, systemImage: cacheSymbol(cache.temperature))
        } else {
            Image(systemName: cacheSymbol(cache.temperature))
                .accessibilityLabel(cache.displayText)
        }
    }

    private func usageColor(_ fraction: Double) -> Color {
        if fraction >= 0.90 { return .red }
        if fraction >= 0.75 { return .orange }
        return snapshot.id.tint
    }

    private func reuseColor(_ fraction: Double) -> Color {
        CacheReusePresentation.tint(for: fraction)
    }

    private func cacheSymbol(_ temperature: CacheTemperature) -> String {
        switch temperature {
        case .warm: "flame.fill"
        case .expiring: "timer"
        case .cold: "snowflake"
        case .unknown: "questionmark.circle"
        }
    }

    private var activityLabel: String {
        if snapshot.sessions.contains(where: { $0.status == .working }) {
            return "Active now"
        }
        if snapshot.sessions.contains(where: { $0.status.requiresAttention }) {
            return "Needs attention"
        }
        return "Connected"
    }

    private var sessionCountLabel: String {
        let count = snapshot.sessions.count
        return count == 1 ? "1 session" : "\(count) sessions"
    }

    private var connectionMessage: String {
        switch snapshot.connectionState {
        case .connected:
            "Connected · no active session"
        case let .degraded(message):
            "Connector issue: \(message)"
        case .unavailable:
            "Unavailable"
        }
    }
}
