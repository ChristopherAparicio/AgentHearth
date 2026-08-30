import AgentHearthCore
import Foundation

struct ExpiringCacheItem: Identifiable {
    let session: AgentSession
    let expiresAt: Date

    var id: String {
        "\(session.providerID.rawValue):\(session.host.id):\(session.id)"
    }
}

extension AppModel {
    var visibleSnapshots: [ProviderSnapshot] {
        snapshots
            .filter { snapshot in
                !hiddenProviders.contains(snapshot.id) && snapshot.connectionState != .unavailable
            }
            .map { snapshot in
                ProviderSnapshot(
                    id: snapshot.id,
                    connectionState: snapshot.connectionState,
                    sessions: sessionDisplayPolicy.sessions(from: focusFiltered(snapshot.sessions)),
                    usageWindows: snapshot.usageWindows,
                    updatedAt: snapshot.updatedAt
                )
            }
    }

    /// In Priority-only mode the list mirrors the notification focus and shows
    /// pinned sessions only. With no pins yet the filter is inert, so the mode
    /// can be armed before the first star without blanking the menu.
    private func focusFiltered(_ sessions: [AgentSession]) -> [AgentSession] {
        let focus = sessionFocus.preferences
        guard focus.mode == .priorityOnly, !focus.pinned.isEmpty else { return sessions }
        return sessions.filter { focus.isPinned($0) }
    }

    var sessionDisplayPolicy: SessionDisplayPolicy {
        SessionDisplayPolicy(
            window: sessionDisplayWindow,
            maximumPerProvider: maximumVisibleSessions,
            pinned: sessionFocus.pinnedRefs
        )
    }

    var displayedSnapshots: [ProviderSnapshot] {
        let providerScoped = switch selection {
        case .all:
            hostScopedSnapshots
        case let .provider(providerID):
            hostScopedSnapshots.filter { $0.id == providerID }
        }
        guard case let .server(serverID) = openCodeServerSelection,
              isOpenCodeView
        else { return providerScoped }
        return providerScoped.compactMap { snapshot in
            guard snapshot.id == .openCode else { return snapshot }
            return ProviderSnapshot(
                id: snapshot.id,
                connectionState: snapshot.connectionState,
                sessions: snapshot.sessions.filter { $0.source?.id == serverID },
                usageWindows: snapshot.usageWindows,
                updatedAt: snapshot.updatedAt
            )
        }
    }

    var isOpenCodeView: Bool {
        if selection == .provider(.openCode) { return true }
        return selection == .all
            && hostScopedSnapshots.count == 1
            && hostScopedSnapshots.first?.id == .openCode
    }

    var availableOpenCodeServers: [OpenCodeServerConfiguration] {
        openCodeServersService.openCodeServers.filter { server in
            guard server.isEnabled else { return false }
            if case let .host(hostID) = hostSelection { return server.hostID == hostID }
            return true
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var selectedOpenCodeServer: OpenCodeServerConfiguration? {
        guard case let .server(serverID) = openCodeServerSelection else { return nil }
        return availableOpenCodeServers.first { $0.id == serverID }
    }

    /// Cache countdowns follow the provider and machine filters currently
    /// selected in the menu bar. Remaining time is anchored to the refresh that
    /// produced the snapshot so SwiftUI redraws do not reset the countdown.
    var expiringCacheItems: [ExpiringCacheItem] {
        let warningSeconds = alertRules.preferences.cacheWarningSeconds
        guard warningSeconds > 0 else { return [] }
        let measuredAt = lastRefreshAt ?? .now

        return displayedSnapshots
            .flatMap(\.sessions)
            .compactMap { session in
                guard session.cache.temperature == .warm || session.cache.temperature == .expiring,
                      let remaining = session.cache.remainingSeconds,
                      remaining > 0,
                      remaining <= warningSeconds
                else { return nil }
                return ExpiringCacheItem(
                    session: session,
                    expiresAt: measuredAt.addingTimeInterval(TimeInterval(remaining))
                )
            }
            .sorted { lhs, rhs in
                if lhs.expiresAt != rhs.expiresAt { return lhs.expiresAt < rhs.expiresAt }
                return lhs.session.title.localizedCaseInsensitiveCompare(rhs.session.title) == .orderedAscending
            }
    }

    var currentViewScopeDescription: String {
        let provider: String
        switch selection {
        case .all: provider = "All providers"
        case let .provider(providerID): provider = providerID.displayName
        }
        let machine = selectedHost?.displayName ?? "all machines"
        let server = selectedOpenCodeServer.map { " · \($0.displayName)" } ?? ""
        return "\(provider) · \(machine)\(server)"
    }

    var hostScopedSnapshots: [ProviderSnapshot] {
        guard case let .host(hostID) = hostSelection else { return visibleSnapshots }
        return visibleSnapshots.compactMap { snapshot in
            let sessions = snapshot.sessions.filter { $0.host.id == hostID }
            let windows = snapshot.usageWindows.filter { $0.host.id == hostID }
            guard !sessions.isEmpty || !windows.isEmpty else { return nil }
            return ProviderSnapshot(
                id: snapshot.id,
                connectionState: snapshot.connectionState,
                sessions: sessions,
                usageWindows: windows,
                updatedAt: snapshot.updatedAt
            )
        }
    }

    var availableHosts: [AgentHost] {
        var values = [AgentHost.local]
        values.append(contentsOf: remoteHostsService.remoteHosts.filter(\.isEnabled).map(\.host))
        values.append(contentsOf: visibleSnapshots.flatMap(\.sessions).map(\.host))
        values.append(contentsOf: visibleSnapshots.flatMap(\.usageWindows).map(\.host))
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { lhs, rhs in
                if lhs.kind == .local, rhs.kind != .local { return true }
                if rhs.kind == .local, lhs.kind != .local { return false }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    var selectedHost: AgentHost? {
        guard case let .host(hostID) = hostSelection else { return nil }
        return availableHosts.first { $0.id == hostID }
    }

    var sessions: [AgentSession] {
        snapshots
            .filter { snapshot in
                !hiddenProviders.contains(snapshot.id) && snapshot.connectionState != .unavailable
            }
            .flatMap(\.sessions)
    }

    var workingCount: Int {
        sessions.count { $0.status == .working }
    }

    var attentionCount: Int {
        sessions.count { $0.status.requiresAttention }
    }

    var warmCacheCount: Int {
        sessions.count { $0.cache.temperature == .warm || $0.cache.temperature == .expiring }
    }

    /// The configurable menu-bar text. Nil renders the flame icon alone —
    /// including when the selected usage window currently reports no data.
    var menuBarTitle: String? {
        switch menuBarDisplayMode {
        case .iconOnly:
            return nil
        case .sessionCounts:
            return menuBarSummary
        case .usageWindow:
            guard let selection = menuBarUsageWindow,
                  let window = snapshots.first(where: { $0.id == selection.providerID })?
                      .usageWindows.first(where: { $0.id == selection.windowID })
            else { return nil }
            return "\(Int((window.usedFraction * 100).rounded()))%"
        case .cacheReuse:
            guard let average = averageCacheReuse else { return nil }
            return "\(Int((average * 100).rounded()))%"
        }
    }

    /// Mean cache reuse across the visible sessions that report one, weighing
    /// each session equally — the same per-session metric the rows display.
    var averageCacheReuse: Double? {
        let rates = visibleSnapshots.flatMap(\.sessions).compactMap { session in
            session.cacheHealth?.tokenReuseRate ?? session.cache.cacheReuseRate
        }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }

    /// Usage windows currently reported by any provider, plus the stored
    /// selection when its provider is offline, so Settings can always render
    /// the active choice.
    var availableMenuBarUsageWindows: [MenuBarUsageWindowSelection] {
        var choices: [MenuBarUsageWindowSelection] = snapshots.flatMap { snapshot in
            snapshot.usageWindows.map { window in
                MenuBarUsageWindowSelection(
                    providerID: snapshot.id,
                    windowID: window.id,
                    label: "\(snapshot.id.displayName) · \(window.label)"
                )
            }
        }
        if let selection = menuBarUsageWindow, !choices.contains(where: { $0.id == selection.id }) {
            choices.append(selection)
        }
        return choices.sorted { $0.label < $1.label }
    }

    /// Pinned sessions within the current provider scope. Drives the
    /// Priority-only toggle's enablement and count badge, so a tab with no
    /// starred session shows the control as inert instead of a dead click.
    var scopedPinnedSessionCount: Int {
        let scoped: [ProviderSnapshot]
        if case let .provider(providerID) = selection {
            scoped = hostScopedSnapshots.filter { $0.id == providerID }
        } else {
            scoped = hostScopedSnapshots
        }
        return scoped.flatMap(\.sessions).count { sessionFocus.isPinned($0) }
    }

    var menuBarSummary: String {
        let base = sessions.isEmpty ? "Hearth" : "\(workingCount) · \(attentionCount)"
        guard let usage = menuBarUsageBadge else { return base }
        return "\(base) · \(usage)"
    }

    /// Standing usage badge for the menu bar: the highest window utilization
    /// across providers, shown once it crosses the lowest configured usage
    /// alert threshold. Notifications announce the crossing; this keeps it
    /// visible afterwards, since a menu-bar app has no Dock icon to badge.
    var menuBarUsageBadge: String? {
        let preferences = alertRules.preferences
        guard preferences.notificationsEnabled, preferences.usageLimitEnabled,
              let lowestThreshold = preferences.usageAlertThresholds.map(\.percentage).min(),
              let highestFraction = visibleSnapshots.flatMap(\.usageWindows).map(\.usedFraction).max()
        else { return nil }
        let percent = Int((highestFraction * 100).rounded())
        guard percent >= lowestThreshold else { return nil }
        return "\(percent)%"
    }

    func normalizeSelection() {
        if case let .host(hostID) = hostSelection,
           !availableHosts.contains(where: { $0.id == hostID }) {
            hostSelection = .all
        }
        if !isOpenCodeView {
            openCodeServerSelection = .all
        } else if case let .server(serverID) = openCodeServerSelection,
                  !availableOpenCodeServers.contains(where: { $0.id == serverID }) {
            openCodeServerSelection = .all
        }
        guard case let .provider(providerID) = selection else { return }
        if !hostScopedSnapshots.contains(where: { $0.id == providerID }) {
            selection = .all
        }
    }

    func host(for hostID: String) -> AgentHost? {
        if hostID == AgentHost.local.id { return .local }
        return remoteHostsService.remoteHosts.first { $0.id == hostID }?.host
    }
}
