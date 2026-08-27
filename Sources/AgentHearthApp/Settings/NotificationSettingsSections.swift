import AgentHearthCore
import SwiftUI

/// The Notifications section: the macOS permission surface, the alert
/// category toggles, and the test notification.
struct NotificationsSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var alertRules = model.alertRules
        Section("Notifications") {
            Toggle("Enable macOS notifications", isOn: $alertRules.preferences.notificationsEnabled)

            HStack(spacing: 7) {
                Image(systemName: model.notificationAdmin.authorization.systemImage)
                    .foregroundStyle(authorizationColor)
                Text(model.notificationAdmin.authorization.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(authorizationColor)

                Spacer()

                switch model.notificationAdmin.authorization {
                case .denied:
                    Button("Open System Settings") {
                        model.notificationAdmin.openSystemSettings()
                    }
                case .notDetermined:
                    Button("Allow") {
                        model.notificationAdmin.requestAuthorization()
                    }
                case .allowed, .quiet:
                    Button {
                        model.notificationAdmin.refreshAuthorization()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh notification permission")
                }
            }

            if model.notificationAdmin.authorization == .denied {
                Text("macOS has blocked notifications for AgentHearth. Open Notifications in System Settings to allow banners, sounds, and badges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(permissionDetails)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Send Test Notification") {
                model.notificationAdmin.sendTestNotification()
            }
            .disabled(
                !model.alertRules.preferences.notificationsEnabled
                    || model.notificationAdmin.authorization == .denied
            )

            if let result = model.notificationAdmin.lastTestResult {
                Label(result.label, systemImage: testResultSymbol(result))
                    .font(.caption)
                    .foregroundStyle(testResultColor(result))
            }

            Group {
                Toggle("Waiting, approval, stuck, or failed", isOn: $alertRules.preferences.sessionAttentionEnabled)
                Toggle("Agent finished", isOn: $alertRules.preferences.sessionCompletionEnabled)
                Toggle("Prompt cache close to expiry", isOn: $alertRules.preferences.cacheExpiryEnabled)
                Toggle("Usage limit alerts", isOn: $alertRules.preferences.usageLimitEnabled)
                UsageAlertThresholdSettings(model: model)
                    .disabled(!model.alertRules.preferences.usageLimitEnabled)
                Toggle("Sounds", isOn: $model.notificationPolicy.soundsEnabled)
                Toggle("Silence ordinary sounds in Night mode", isOn: $model.notificationPolicy.silenceSoundsInNightMode)
                Toggle("Allow critical sounds in Night mode", isOn: $model.notificationPolicy.allowCriticalSoundsInNightMode)
            }
            .disabled(!model.alertRules.preferences.notificationsEnabled)

            Text("Clicking a session notification uses the destination selected in Opening Sessions. Night mode keeps active agents awake while muting ordinary sounds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var authorizationColor: Color {
        switch model.notificationAdmin.authorization {
        case .allowed: .green
        case .quiet: .orange
        case .notDetermined: .secondary
        case .denied: .red
        }
    }

    private var permissionDetails: String {
        let status = model.notificationAdmin.permissionStatus
        let badge = status.badgesEnabled ? "on" : "off"
        let sound = status.soundsEnabled ? "on" : "off"
        return "\(status.deliveryDescription) · Badge \(badge) · Sound \(sound)"
    }

    private func testResultSymbol(_ result: NotificationDeliveryResult) -> String {
        switch result {
        case .submitted: "clock"
        case .presented: "checkmark.circle.fill"
        case .blocked, .failed: "exclamationmark.triangle.fill"
        }
    }

    private func testResultColor(_ result: NotificationDeliveryResult) -> Color {
        switch result {
        case .submitted: .orange
        case .presented: .green
        case .blocked, .failed: .red
        }
    }
}

/// The Cache Expiry section: the per-profile warning policies, the
/// notification scopes, and the live expiring-cache list.
struct CacheExpirySettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Cache Expiry") {
            Text("Configure each cache policy independently. AgentHearth sends one warning when a live cache first enters its selected interval, including if it is already close to expiry when discovered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.alertRules.cacheNotificationProfiles) { profile in
                CacheNotificationProfileRow(model: model, profile: profile)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Notification scope")
                    .font(.caption.weight(.semibold))

                Text("Profiles define the default. Use project or session exceptions only for work you do not want to interrupt you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !model.alertRules.cacheNotificationProjects.isEmpty {
                    Divider()
                    ProjectNotificationScopeView(model: model)
                }
            }
            .disabled(!model.alertRules.preferences.cacheExpiryEnabled || !model.alertRules.preferences.notificationsEnabled)

            LabeledContent("Current menu view", value: model.currentViewScopeDescription)

            if model.expiringCacheItems.isEmpty {
                Label("No cache expires within the selected interval", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ExpiringCacheList(
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
            }

            Text("Countdowns are exact when the provider exposes its cache policy; otherwise AgentHearth shows ~ to mark an estimate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CacheNotificationProfileRow: View {
    @Bindable var model: AppModel
    let profile: CacheNotificationProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Toggle(profile.settingsLabel, isOn: Binding(
                    get: { model.alertRules.cacheNotificationProfileEnabled(profile) },
                    set: { model.alertRules.setCacheNotificationProfile(profile, enabled: $0) }
                ))

                Spacer()

                Picker("Warning time", selection: Binding(
                    get: { model.alertRules.cacheNotificationWarningSeconds(profile) },
                    set: { model.alertRules.setCacheNotificationProfile(profile, warningSeconds: $0) }
                )) {
                    ForEach([60, 180, 300, 600, 900], id: \.self) { seconds in
                        Text(cacheWarningLabel(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
                .disabled(!model.alertRules.cacheNotificationProfileEnabled(profile))
            }

            Text(profile.cacheDocumentation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func cacheWarningLabel(_ seconds: Int) -> String {
        "\(seconds / 60) min"
    }
}

private struct UsageAlertThresholdSettings: View {
    @Bindable var model: AppModel

    private let sounds = ["Tink", "Pop", "Bottle", "Funk", "Sosumi", "Basso", "Hero"]
    private let percentages = [50, 60, 70, 80, 85, 90, 95, 100]

    var body: some View {
        @Bindable var alertRules = model.alertRules
        return VStack(alignment: .leading, spacing: 6) {
            Text("Usage alert sounds")
                .font(.caption.weight(.semibold))

            ForEach($alertRules.preferences.usageAlertThresholds) { $threshold in
                HStack(spacing: 8) {
                    Picker("Threshold", selection: $threshold.percentage) {
                        ForEach(percentages, id: \.self) { percentage in
                            Text("\(percentage)%").tag(percentage)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 82)

                    Picker("Sound", selection: $threshold.soundName) {
                        ForEach(sounds, id: \.self) { sound in
                            Text(sound).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)

                    Button {
                        model.notificationAdmin.previewSound(named: threshold.soundName)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview sound")
                }
            }
        }
        .font(.caption)
    }
}

private extension CacheNotificationProfile {
    var settingsLabel: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .openCodeOpenAI: "OpenCode · OpenAI"
        case .openCodeAnthropic: "OpenCode · Anthropic"
        case .openCodeOther: "OpenCode · Other provider"
        }
    }

    var cacheDocumentation: String {
        switch self {
        case .codex:
            "GPT-5.6 caches are tracked with a 30-minute policy; unknown Codex models fall back to 5 minutes."
        case .claudeCode:
            "Claude exposes a 5-minute or 1-hour cache bucket when transcript telemetry is available."
        case .openCodeOpenAI:
            "Detected from GPT/o-series model IDs. GPT-5.6 uses a 30-minute policy; other models use the reported or inferred TTL."
        case .openCodeAnthropic:
            "Detected from Claude model IDs. TTL comes from the provider telemetry when OpenCode exposes it."
        case .openCodeOther:
            "The underlying provider is not identifiable from this OpenCode model. AgentHearth only uses the reported or inferred TTL."
        }
    }
}

/// The per-project cache-notification exceptions, grouped by provider with a
/// global search and a collapsed "show more" per group so a long, flat list
/// stays readable.
private struct ProjectNotificationScopeView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var expandedProviders: Set<AgentProviderID> = []

    private let collapsedLimit = 5

    private struct ProviderGroup: Identifiable {
        let provider: AgentProviderID
        let projects: [CacheNotificationProject]
        var id: AgentProviderID { provider }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                searchField
            }

            let groups = groupedProjects()
            if groups.isEmpty {
                Text("No project matches “\(search)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    providerGroup(group)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 130)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    @ViewBuilder
    private func providerGroup(_ group: ProviderGroup) -> some View {
        // While searching, every match is shown; otherwise each group starts
        // collapsed to the first few projects behind a "show more" button.
        let isExpanded = expandedProviders.contains(group.provider) || !search.isEmpty
        let shown = isExpanded ? group.projects : Array(group.projects.prefix(collapsedLimit))

        HStack(spacing: 6) {
            Image(systemName: group.provider.symbolName)
                .font(.caption)
                .foregroundStyle(group.provider.tint)
            Text(group.provider.displayName)
                .font(.caption.weight(.semibold))
            Text("\(group.projects.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)

        ForEach(shown) { project in
            Toggle(label(for: project), isOn: binding(for: project))
                .help("\(project.session.providerID.displayName) on \(project.session.host.displayName)")
        }

        if search.isEmpty, group.projects.count > collapsedLimit {
            if isExpanded {
                Button {
                    expandedProviders.remove(group.provider)
                } label: {
                    Label("Show less", systemImage: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Button {
                    expandedProviders.insert(group.provider)
                } label: {
                    Label("Show \(group.projects.count - collapsedLimit) more", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func groupedProjects() -> [ProviderGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let projects = model.alertRules.cacheNotificationProjects.filter { project in
            guard !query.isEmpty else { return true }
            return project.displayName.localizedCaseInsensitiveContains(query)
                || project.session.host.displayName.localizedCaseInsensitiveContains(query)
                || project.session.providerID.displayName.localizedCaseInsensitiveContains(query)
        }
        return AgentProviderID.allCases.compactMap { provider in
            let matches = projects.filter { $0.session.providerID == provider }
            return matches.isEmpty ? nil : ProviderGroup(provider: provider, projects: matches)
        }
    }

    // Disambiguate same-named projects that live on different SSH hosts.
    private func label(for project: CacheNotificationProject) -> String {
        project.session.host.kind == .ssh
            ? "\(project.displayName) · \(project.session.host.displayName)"
            : project.displayName
    }

    private func binding(for project: CacheNotificationProject) -> Binding<Bool> {
        Binding(
            get: { model.alertRules.cacheNotificationsEnabled(for: project) },
            set: { model.alertRules.setCacheNotificationsEnabled($0, for: project) }
        )
    }
}
