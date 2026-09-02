import AgentHearthCore
import Foundation

extension AppModel {
    func ignoreCacheWarning(for target: SessionTarget) {
        guard let session = sessions.first(where: {
            $0.providerID == target.providerID && $0.id == target.sessionID && $0.host.id == target.host.id
        }) else { return }
        alertRules.ignoreCacheWarning(for: session)
    }

    /// True when at least one status is hidden, so the UI can flag an active filter.
    var isFilteringSessionStatuses: Bool {
        visibleSessionStatuses.count != SessionStatus.allCases.count
    }

    func isSessionStatusVisible(_ status: SessionStatus) -> Bool {
        visibleSessionStatuses.contains(status)
    }

    func toggleSessionStatusVisibility(_ status: SessionStatus) {
        if visibleSessionStatuses.contains(status) {
            visibleSessionStatuses.remove(status)
        } else {
            visibleSessionStatuses.insert(status)
        }
    }

    func showAllSessionStatuses() {
        visibleSessionStatuses = Set(SessionStatus.allCases)
    }

    func sessionOpenDestination(for providerID: AgentProviderID) -> SessionOpenDestination {
        sessionOpenPreferences.destination(for: providerID)
    }

    /// Describes what clicking a session's open control will actually do, so the
    /// tooltip matches the configured destination (SSH always resumes in Terminal).
    func openActionHelp(for target: SessionTarget) -> String {
        switch sessionOpenPreferences.effectiveDestination(for: target) {
        case .terminal:
            "Resume in Terminal"
        case .providerApp:
            target.providerID.providerAppOpenHelp
        }
    }

    func setSessionOpenDestination(_ destination: SessionOpenDestination, for providerID: AgentProviderID) {
        sessionOpenPreferences.setDestination(destination, for: providerID)
    }

    func refreshHistoryDashboard() async {
        historyDashboard = await historyStore.dashboard(
            days: historyRangeDays,
            providerID: historyProviderFilter,
            cacheHitThreshold: Double(cacheHitThreshold) / 100
        )
        historyStorageBytes = await historyStore.storageBytes()
    }

    func clearHistory() {
        Task {
            await historyStore.clear()
            await refreshHistoryDashboard()
        }
    }

    /// Every observed session (all providers and hosts) whose prompt cache is
    /// still warm: the candidates for "pin all warm-cache sessions".
    var warmCacheSessions: [AgentSession] {
        snapshots.flatMap(\.sessions).filter(\.hasWarmCache)
    }

    /// Number of warm-cache sessions not pinned yet, for the action labels.
    var unpinnedWarmCacheSessionCount: Int {
        warmCacheSessions.count { !sessionFocus.isPinned($0) }
    }

    /// Pins every session whose cache is still warm, so Priority-only mode
    /// follows exactly the work that would benefit from a follow-up prompt.
    /// Returns how many sessions were newly pinned.
    @discardableResult
    func pinWarmCacheSessions() -> Int {
        sessionFocus.pinAll(warmCacheSessions)
    }

    func setProvider(_ providerID: AgentProviderID, visible: Bool) {
        if visible {
            hiddenProviders.remove(providerID)
        } else {
            hiddenProviders.insert(providerID)
        }
    }

    func setHostSelection(_ selection: HostSelection) {
        hostSelection = selection
        normalizeSelection()
    }

    /// Every provider-selection write goes through here so the dependent
    /// server selection is normalized (e.g. leaving the OpenCode view clears a
    /// stale `.server` scope that would otherwise still label Settings).
    func setSelection(_ selection: ProviderSelection) {
        self.selection = selection
        normalizeSelection()
    }

    /// Views showing the history dashboard register themselves so the refresh
    /// loop only pays for the aggregation while someone is looking at it.
    func beginObservingHistoryDashboard() {
        historyDashboardObservers += 1
        Task { await refreshHistoryDashboard() }
    }

    func endObservingHistoryDashboard() {
        historyDashboardObservers = max(0, historyDashboardObservers - 1)
    }

    func setOpenCodeServerSelection(_ selection: OpenCodeServerSelection) {
        openCodeServerSelection = selection
        normalizeSelection()
    }

    func isProviderVisible(_ providerID: AgentProviderID) -> Bool {
        !hiddenProviders.contains(providerID)
    }

    func sourceMode(for providerID: AgentProviderID) -> ProviderDataSourceMode {
        dataSourceModes[providerID] ?? .automatic
    }

    func setSourceMode(_ mode: ProviderDataSourceMode, for providerID: AgentProviderID) {
        dataSourceModes[providerID] = mode
        Task {
            await monitor.setSourceMode(mode, for: providerID)
            await refresh()
        }
    }

    func openSession(_ target: SessionTarget) {
        sessionOpeningError = nil
        let destination = sessionOpenPreferences.effectiveDestination(for: target)
        Task {
            do {
                try await sessionOpener.open(target, destination: destination)
            } catch {
                sessionOpeningError = error.localizedDescription
            }
        }
    }
}
