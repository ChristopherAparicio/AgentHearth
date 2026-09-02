import AgentHearthCore
import SwiftUI

/// The Providers section: which providers appear in the main view.
struct ProvidersSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Providers") {
            ForEach(AgentProviderID.allCases) { providerID in
                Toggle(providerID.displayName, isOn: Binding(
                    get: { model.isProviderVisible(providerID) },
                    set: { model.setProvider(providerID, visible: $0) }
                ))
            }
            Text("Unavailable providers remain hidden from the main view.")
                .font(.caption)
                .foregroundStyle(.secondary)

            settingsControlRow("Usage reset shows") {
                Picker("Usage reset shows", selection: $model.usageResetDisplay) {
                    ForEach(UsageResetDisplay.allCases) { display in
                        Text(display.label).tag(display)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Text("The 5-hour and 7-day bars show when each window resets, as a countdown or as a clock time. Hovering shows both. A window with no reset yet was measured from a source that does not report one; Claude Code and Codex report it after the first API response of a session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Session List section: how many sessions each provider shows.
struct SessionListSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Session List") {
            settingsControlRow("Maximum per provider") {
                Picker("Maximum sessions", selection: $model.maximumVisibleSessions) {
                    Text("5 sessions").tag(5)
                    Text("10 sessions").tag(10)
                    Text("20 sessions").tag(20)
                    Text("50 sessions").tag(50)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Text("Choose the recent-session period directly from the menu bar. Working and attention-needed sessions remain visible even if they are older than that period.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Session Row section: layout and cache detail of each session row.
struct SessionRowSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Session Row") {
            Toggle("Compact layout", isOn: $model.showsCompactSessionRows)
            Toggle("Show cache status icon", isOn: $model.showsSessionCacheIcon)
            Toggle("Show cache expiry countdown", isOn: $model.showsSessionCacheCountdown)
                .disabled(!model.showsSessionCacheIcon)
            Toggle("Show cache reuse", isOn: $model.showsSessionCacheHits)

            if model.showsSessionCacheHits {
                settingsControlRow("Cache reuse shows") {
                    Picker("Cache reuse shows", selection: $model.cacheReuseDisplayMode) {
                        ForEach(CacheReuseDisplayMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Text("Compact layout fits each session on one line so more are visible at once. Cache reuse can show the whole session (cold starts included), just the last turn, or both.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Opening Sessions section: the per-provider open destination.
struct SessionOpeningSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Opening Sessions") {
            ForEach(AgentProviderID.allCases) { providerID in
                settingsControlRow(providerID.displayName) {
                    Picker("Open \(providerID.displayName) sessions", selection: sessionOpenDestinationBinding(for: providerID)) {
                        Text(providerID.appDestinationLabel).tag(SessionOpenDestination.providerApp)
                        Text("Terminal · resume session").tag(SessionOpenDestination.terminal)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Text("This choice is also used when you click an AgentHearth notification. Terminal resumes the exact CLI session. Claude opens the exact session in its desktop app, the Codex app opens without a session, and OpenCode opens the local project. SSH sessions always open in Terminal on their source machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sessionOpenDestinationBinding(for providerID: AgentProviderID) -> Binding<SessionOpenDestination> {
        Binding(
            get: { model.sessionOpenDestination(for: providerID) },
            set: { model.setSessionOpenDestination($0, for: providerID) }
        )
    }
}

/// The Claude Usage Limits section: the opt-in account usage poller.
struct ClaudeUsageSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Claude Usage Limits") {
            Toggle("Fetch reset times from Anthropic", isOn: Binding(
                get: { model.accountUsagePoller.isEnabled },
                set: { model.accountUsagePoller.setEnabled($0) }
            ))

            if let status = model.accountUsagePoller.status, model.accountUsagePoller.isEnabled {
                LabeledContent("Status", value: status)
                    .font(.caption)
            }

            Text("Off by default. When on, AgentHearth reads your existing Claude sign-in from the Keychain to fetch the 5h/7d reset times from Anthropic about every two hours — the only source that works without an open terminal session. The token is read once per launch and kept in memory; it is never stored, refreshed, or sent anywhere but api.anthropic.com.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.accountUsagePoller.isEnabled {
                Label {
                    Text("macOS asks for your consent the first time, sometimes with two dialogs in a row: one to unlock the login keychain (only while it is locked), then one for the “Claude Code-credentials” item itself. Choose Always Allow on the second one so it is not asked again.")
                } icon: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// The Data Sources section: the per-provider data source mode.
struct DataSourcesSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Data Sources") {
            ForEach(AgentProviderID.allCases) { providerID in
                settingsControlRow(providerID.displayName) {
                    Picker("Source", selection: Binding(
                        get: { model.sourceMode(for: providerID) },
                        set: { model.setSourceMode($0, for: providerID) }
                    )) {
                        ForEach(ProviderDataSourceMode.allCases) { mode in
                            Text(mode.settingsLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            Text("Automatic combines local history with live hooks or plugins. Local only never uses pushed events. Realtime only shows data received after the integration starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The Privacy section: the local-first data statement.
struct PrivacySettingsSection: View {
    var body: some View {
        Section("Privacy") {
            Text("AgentHearth is local-first. Provider adapters must not collect raw prompts, source code, or secret values.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension ProviderDataSourceMode {
    var settingsLabel: String {
        switch self {
        case .automatic: "Automatic"
        case .localOnly: "Local only"
        case .realtimeOnly: "Realtime only"
        }
    }
}
