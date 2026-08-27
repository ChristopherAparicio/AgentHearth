import AgentHearthCore
import SwiftUI

/// The searchable Settings sections. Each case carries its own search
/// keywords, so section visibility and the "no results" fallback always read
/// the same index and cannot drift apart.
private enum SettingsSection: CaseIterable {
    case providers
    case menuBar
    case sessionList
    case sessionRow
    case openingSessions
    case claudeUsage
    case dataSources
    case remoteHosts
    case openCodeServers
    case openCodeConnector
    case codexConnector
    case claudeCodeConnector
    case notifications
    case prioritySessions
    case cacheExpiry
    case historyReports
    case privacy

    var searchTerms: String {
        switch self {
        case .providers:
            "Providers provider visibility unavailable agent \(Self.providerNames)"
        case .menuBar:
            "Menu Bar icon badge percentage usage window cache reuse counts display flame show next to the icon session counts icon only"
        case .sessionList:
            "Sessions session list maximum limit provider menu bar Codex Claude OpenCode maximum per provider compact layout"
        case .sessionRow:
            "Session Row cache icon temperature warm cold countdown duration hits layout display show cache status icon show cache expiry countdown show cache reuse last turn"
        case .openingSessions:
            "Opening Sessions open resume terminal application app notification Codex Claude Code OpenCode remote SSH"
        case .claudeUsage:
            "Claude usage limits reset five hour seven day account Anthropic token keychain fetch reset times"
        case .dataSources:
            "Data Sources source automatic local realtime \(Self.providerNames)"
        case .remoteHosts:
            "Remote Hosts remote SSH install update test connection uninstall remove machine agent add ssh host name user@host"
        case .openCodeServers:
            "OpenCode Servers server loopback port machine remote local add test remove add server"
        case .openCodeConnector:
            "OpenCode Connector hooks connector install update receiver local status check status plugin"
        case .codexConnector:
            "Codex Connector hooks rollout cache quota session install update live check status"
        case .claudeCodeConnector:
            "Claude Code Connector hooks cache session usage status line install update live check status"
        case .notifications:
            "Notifications alert macOS permission system settings banners sounds badges waiting approval stuck failed finished cache expiry usage limit night mode enable macOS notifications send test notification allow critical sounds silence ordinary agent finished open system settings"
        case .prioritySessions:
            "Priority Sessions pinned pin star focus priority only promote prioritize new session notification unpin remove ask to prioritize show notify"
        case .cacheExpiry:
            "Cache Expiry cache warning countdown notification scope provider project acknowledge ignore prompt cache close to expiry seconds"
        case .historyReports:
            "History Reports cache insights retention dashboard morning daily recap weekly notification storage clear local database store cache history cache-hit threshold default dashboard period first activity weekly report time"
        case .privacy:
            "Privacy local first prompts source code secret values data"
        }
    }

    private static let providerNames = AgentProviderID.allCases.map(\.displayName).joined(separator: " ")
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var pendingRemoteUninstall: RemoteHostConfiguration?
    @State private var isConfirmingHistoryClear = false
    @State private var settingsSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Settings", text: $settingsSearchText)
                    .textFieldStyle(.plain)
                if !settingsSearchText.isEmpty {
                    Button {
                        settingsSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Form {
            Group {
            if matchesSettingsSearch(.providers) {
                ProvidersSettingsSection(model: model)
            }

            if matchesSettingsSearch(.menuBar) {
                MenuBarSettingsSection(model: model)
            }

            if matchesSettingsSearch(.sessionList) {
                SessionListSettingsSection(model: model)
            }

            if matchesSettingsSearch(.sessionRow) {
                SessionRowSettingsSection(model: model)
            }

            if matchesSettingsSearch(.openingSessions) {
                SessionOpeningSettingsSection(model: model)
            }

            if matchesSettingsSearch(.claudeUsage) {
                ClaudeUsageSettingsSection(model: model)
            }

            }

            Group {
            if matchesSettingsSearch(.dataSources) {
                DataSourcesSettingsSection(model: model)
            }

            if matchesSettingsSearch(.remoteHosts) {
                RemoteHostsSettingsSection(
                    model: model,
                    pendingRemoteUninstall: $pendingRemoteUninstall
                )
            }

            }

            Group {
            if matchesSettingsSearch(.openCodeServers) {
                OpenCodeServersSettingsSection(model: model)
            }

            if matchesSettingsSearch(.openCodeConnector) {
                OpenCodeConnectorSettingsSection(model: model)
            }

            }

            Group {
            if matchesSettingsSearch(.codexConnector) {
                CodexConnectorSettingsSection(model: model)
            }

            if matchesSettingsSearch(.claudeCodeConnector) {
                ClaudeCodeConnectorSettingsSection(model: model)
            }

            if matchesSettingsSearch(.notifications) {
                NotificationsSettingsSection(model: model)
            }

            if matchesSettingsSearch(.prioritySessions) {
                PrioritySessionsSettingsSection(model: model)
            }

            }

            Group {
            if matchesSettingsSearch(.cacheExpiry) {
                CacheExpirySettingsSection(model: model)
            }

            if matchesSettingsSearch(.historyReports) {
                HistoryReportsSettingsSection(
                    model: model,
                    isConfirmingHistoryClear: $isConfirmingHistoryClear
                )
            }

            if matchesSettingsSearch(.privacy) {
                PrivacySettingsSection()
            }

            }

            if !hasMatchingSettingsSection {
                ContentUnavailableView.search(text: settingsSearchText)
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .formStyle(.grouped)
        .padding()
        }
        .frame(width: 640, height: 780)
        .onAppear {
            model.notificationAdmin.refreshAuthorization()
            model.connectorInstallation.refreshOpenCodeInstallationState()
            model.connectorInstallation.refreshCodexInstallationState()
            model.connectorInstallation.refreshClaudeCodeInstallationState()
            for host in model.remoteHostsService.remoteHosts {
                model.remoteHostsService.checkRemoteHost(host)
            }
            for server in model.openCodeServersService.openCodeServers where server.isEnabled {
                model.openCodeServersService.checkOpenCodeServer(server)
            }
        }
        .onChange(of: model.alertRules.preferences.notificationsEnabled) { _, isEnabled in
            if isEnabled { model.notificationAdmin.requestAuthorization() }
        }
        .confirmationDialog(
            "Clear all local cache history?",
            isPresented: $isConfirmingHistoryClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes AgentHearth's local analytics database. Provider sessions and their own history are not changed.")
        }
        .confirmationDialog(
            "Uninstall AgentHearth from \(pendingRemoteUninstall?.displayName ?? "remote host")?",
            isPresented: Binding(
                get: { pendingRemoteUninstall != nil },
                set: { if !$0 { pendingRemoteUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let host = pendingRemoteUninstall {
                Button("Uninstall Remote Agent", role: .destructive) {
                    model.remoteHostsService.uninstallRemoteAgent(host)
                    pendingRemoteUninstall = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoteUninstall = nil
            }
        } message: {
            Text("This stops the remote service and removes only AgentHearth's collector, state files, and OpenCode plugin. Your SSH configuration and provider sessions are preserved.")
        }
    }

    private var hasMatchingSettingsSection: Bool {
        SettingsSection.allCases.contains(where: matchesSettingsSearch)
    }

    private func matchesSettingsSearch(_ section: SettingsSection) -> Bool {
        let queryTerms = settingsSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })

        guard !queryTerms.isEmpty else { return true }

        let searchableText = section.searchTerms
        return queryTerms.allSatisfy { term in
            searchableText.localizedStandardContains(String(term))
        }
    }
}
