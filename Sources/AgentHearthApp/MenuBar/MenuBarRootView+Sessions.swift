import AgentHearthCore
import SwiftUI

extension MenuBarRootView {
    var summary: some View {
        HStack(spacing: 8) {
            SummaryMetric(
                value: workingCount,
                label: "Working",
                symbol: "bolt.fill",
                color: .green,
                isSelected: sessionFilter == .working,
                action: { toggleFilter(.working) }
            )
            SummaryMetric(
                value: attentionCount,
                label: "Attention",
                symbol: "exclamationmark",
                color: .yellow,
                isSelected: sessionFilter == .attention,
                action: { toggleFilter(.attention) }
            )
            SummaryMetric(
                value: warmCacheCount,
                label: "Warm cache",
                symbol: "flame.fill",
                color: .orange,
                isSelected: sessionFilter == .warmCache,
                action: { toggleFilter(.warmCache) }
            )
        }
    }

    @ViewBuilder
    var providerContent: some View {
        if model.displayedSnapshots.isEmpty {
            emptyState
        } else {
            ScrollView {
                if !model.expiringCacheItems.isEmpty {
                    ExpiringCachePanel(
                        items: model.expiringCacheItems,
                        onOpenSession: model.openSession,
                        cacheAlertDisposition: model.alertRules.cacheAlertDisposition,
                        cacheNotificationsEnabled: model.alertRules.cacheNotificationsEnabled,
                        hasSessionRule: { model.alertRules.hasCacheNotificationRule(.session, for: $0) },
                        onAcknowledgeCache: model.alertRules.acknowledgeCacheWarning,
                        onIgnoreCache: model.alertRules.ignoreCacheWarning,
                        onSetSessionNotificationsEnabled: { enabled, session in
                            model.alertRules.setCacheNotificationsEnabled(enabled, for: session)
                        },
                        onClearSessionRule: model.alertRules.clearCacheNotificationRule
                    )
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                }

                if filteredSnapshots.isEmpty {
                    noMatchingSessionState
                        .frame(minHeight: 250)
                } else {
                    if let sessionFilter {
                        filterHeader(sessionFilter)
                            .padding(.top, 11)
                            .padding(.bottom, 8)
                    }

                    // A plain VStack: the list is a handful of cards, and
                    // LazyVStack's item caching reused a Dashboard summary card
                    // for the same provider when switching to its tab. Explicit
                    // per-flavor ids keep identities distinct as well.
                    VStack(spacing: 10) {
                        if model.selection == .all, sessionFilter == nil {
                            // Dashboard: every provider's limits first, then the
                            // pinned work grouped per provider below.
                            ForEach(filteredSnapshots) { snapshot in
                                providerCard(snapshot, content: .usageSummary)
                                    .id("summary-\(snapshot.id.rawValue)")
                            }

                            let prioritySnapshots = filteredSnapshots.filter { snapshot in
                                snapshot.sessions.contains(where: model.sessionFocus.isPinned)
                            }
                            if !prioritySnapshots.isEmpty {
                                prioritySectionHeader
                                    .padding(.top, 6)
                                ForEach(prioritySnapshots) { snapshot in
                                    providerCard(snapshot, content: .prioritySessions)
                                        .id("priority-\(snapshot.id.rawValue)")
                                }
                            }
                        } else {
                            ForEach(filteredSnapshots) { snapshot in
                                providerCard(snapshot, content: .full)
                                    .id("full-\(snapshot.id.rawValue)")
                            }
                        }
                    }
                    .padding(.bottom, 12)
                    .padding(.top, sessionFilter == nil ? 10 : 0)
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var prioritySectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text("Priority sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func providerCard(_ snapshot: ProviderSnapshot, content: ProviderCardContent) -> some View {
        ProviderCardView(
            snapshot: snapshot,
            onOpenSession: model.openSession,
            openSessionHelp: model.openActionHelp,
            cacheAlertDisposition: model.alertRules.cacheAlertDisposition,
            cacheNotificationsEnabled: model.alertRules.cacheNotificationsEnabled,
            hasSessionRule: { model.alertRules.hasCacheNotificationRule(.session, for: $0) },
            onAcknowledgeCache: model.alertRules.acknowledgeCacheWarning,
            onIgnoreCache: model.alertRules.ignoreCacheWarning,
            onSetSessionNotificationsEnabled: { enabled, session in
                model.alertRules.setCacheNotificationsEnabled(enabled, for: session)
            },
            onClearSessionRule: model.alertRules.clearCacheNotificationRule,
            isPinned: model.sessionFocus.isPinned,
            onTogglePin: { model.sessionFocus.togglePin($0) },
            showsCacheIcon: model.showsSessionCacheIcon,
            showsCacheCountdown: model.showsSessionCacheCountdown,
            showsCacheHits: model.showsSessionCacheHits,
            cacheReuseDisplayMode: model.cacheReuseDisplayMode,
            compact: model.showsCompactSessionRows,
            content: content,
            onSelectProvider: { model.setSelection(.provider($0)) }
        )
    }

    private var scopedSessions: [AgentSession] {
        model.displayedSnapshots.flatMap(\.sessions)
    }

    var workingCount: Int {
        scopedSessions.count { $0.status == .working }
    }

    var attentionCount: Int {
        scopedSessions.count { $0.status.requiresAttention }
    }

    private var warmCacheCount: Int {
        scopedSessions.count { $0.cache.temperature == .warm || $0.cache.temperature == .expiring }
    }

    private var filteredSnapshots: [ProviderSnapshot] {
        // No filtering active: return snapshots untouched so usage windows show.
        if sessionFilter == nil, !model.isFilteringSessionStatuses {
            return model.displayedSnapshots
        }
        let visibleStatuses = model.visibleSessionStatuses
        return model.displayedSnapshots.compactMap { snapshot in
            let sessions = snapshot.sessions.filter { session in
                visibleStatuses.contains(session.status)
                    && (sessionFilter?.matches(session) ?? true)
            }
            // Keep a provider whose sessions all filtered out only if it still
            // has usage windows to show; otherwise drop it from the list.
            guard !sessions.isEmpty || !snapshot.usageWindows.isEmpty else { return nil }
            return ProviderSnapshot(
                id: snapshot.id,
                connectionState: snapshot.connectionState,
                sessions: sessions,
                usageWindows: snapshot.usageWindows,
                updatedAt: snapshot.updatedAt
            )
        }
    }

    private func toggleFilter(_ filter: SessionMetricFilter) {
        withAnimation(.easeInOut(duration: 0.16)) {
            sessionFilter = sessionFilter == filter ? nil : filter
        }
    }

    private func filterHeader(_ filter: SessionMetricFilter) -> some View {
        HStack(spacing: 7) {
            Image(systemName: filter.symbol)
                .foregroundStyle(filter.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(filter.title)
                    .font(.caption.weight(.semibold))
                Text(filter.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                toggleFilter(filter)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 21, height: 21)
                    .background(.quaternary.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Clear filter")
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.selectedHost.map { "No session on \($0.displayName)" } ?? "No active provider")
                .font(.headline)
            Text(emptyStateExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Open Settings") { SettingsWindowPresenter.shared.show(model: model) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateExplanation: String {
        if let host = model.selectedHost {
            return "\(host.displayName) is configured, but no active, attention, or warm-cache session is currently visible."
        }
        return "Providers appear here as soon as AgentHearth observes relevant activity."
    }

    private var noMatchingSessionState: some View {
        VStack(spacing: 9) {
            Image(systemName: sessionFilter?.symbol ?? "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(sessionFilter?.color ?? .secondary)
            Text("No matching session")
                .font(.headline)
            Text(noMatchingSessionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Reset every active filter, so the recovery button always clears
            // the empty state regardless of which filter caused it.
            Button("Show all sessions") {
                sessionFilter = nil
                model.showAllSessionStatuses()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchingSessionMessage: String {
        let hiddenStatuses = SessionStatus.allCases.count - model.visibleSessionStatuses.count
        if model.isFilteringSessionStatuses {
            let statusPart = hiddenStatuses == 1
                ? "1 status is hidden"
                : "\(hiddenStatuses) statuses are hidden"
            if let sessionFilter {
                return "\(sessionFilter.emptyMessage) \(statusPart)."
            }
            return "\(statusPart) by the Status filter."
        }
        return sessionFilter?.emptyMessage ?? "No session matches this filter."
    }

    func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SummaryMetric: View {
    let value: Int
    let label: String
    let symbol: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.13), in: Circle())

                Text("\(value)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? color.opacity(0.14) : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? color.opacity(0.55) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Show \(label.lowercased()) sessions")
    }
}

enum SessionMetricFilter: Hashable {
    case working
    case attention
    case warmCache

    func matches(_ session: AgentSession) -> Bool {
        switch self {
        case .working:
            session.status == .working
        case .attention:
            session.status.requiresAttention
        case .warmCache:
            session.cache.temperature == .warm || session.cache.temperature == .expiring
        }
    }

    var title: String {
        switch self {
        case .working: "Working sessions"
        case .attention: "Sessions needing attention"
        case .warmCache: "Sessions with a reusable cache"
        }
    }

    var explanation: String {
        switch self {
        case .working: "The agent is currently processing a request."
        case .attention: "Input, approval, or recovery is required."
        case .warmCache: "The prompt cache is warm or close to expiry."
        }
    }

    var emptyMessage: String {
        switch self {
        case .working: "No agent is currently processing a request."
        case .attention: "No session currently needs your intervention."
        case .warmCache: "No observed prompt cache is currently reusable."
        }
    }

    var symbol: String {
        switch self {
        case .working: "bolt.fill"
        case .attention: "exclamationmark"
        case .warmCache: "flame.fill"
        }
    }

    var color: Color {
        switch self {
        case .working: .green
        case .attention: .yellow
        case .warmCache: .orange
        }
    }
}
