import AgentHearthCore
import Foundation
import Observation

struct CacheNotificationProject: Identifiable {
    let session: AgentSession

    var id: String {
        [session.providerID.rawValue, session.host.id, session.projectName ?? ""].joined(separator: ":")
    }

    var displayName: String { session.projectName ?? "Untitled project" }
}

/// Owns which alerts the user receives: the persisted `AlertPreferences`
/// value — the single write path to its `PreferencesStore` key — and every
/// query and mutation of the provider-, project-, and session-scoped
/// cache-notification rules, profiles, and dispositions.
@MainActor
@Observable
final class AlertRulesService {
    private let store: PreferencesStore

    /// Wired by the composition root: supplies every observed session (all
    /// providers, hidden ones included) so rule targets can be derived.
    @ObservationIgnored var allSessions: () -> [AgentSession] = { [] }

    var preferences: AlertPreferences {
        didSet {
            guard preferences != oldValue else { return }
            store.alertPreferences = preferences
        }
    }

    init(preferences store: PreferencesStore) {
        self.store = store
        self.preferences = store.alertPreferences
    }

    var cacheNotificationProjects: [CacheNotificationProject] {
        let projects = allSessions()
            .filter { $0.projectName?.isEmpty == false }
            .map(CacheNotificationProject.init)
        return Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    var cacheNotificationProfiles: [CacheNotificationProfile] {
        let detected = Set(allSessions().map(CacheNotificationProfile.init(session:)))
        let defaults: [CacheNotificationProfile] = [.codex, .claudeCode]
        return CacheNotificationProfile.allCases.filter { defaults.contains($0) || detected.contains($0) }
    }

    func cacheNotificationsEnabled(for providerID: AgentProviderID) -> Bool {
        guard preferences.cacheExpiryEnabled else { return false }
        return preferences.cacheNotificationRules
            .first(where: { $0.scope == .provider && $0.providerID == providerID })?
            .isEnabled ?? true
    }

    func cacheNotificationsEnabled(for project: CacheNotificationProject) -> Bool {
        preferences.cacheNotificationsEnabled(for: project.session)
    }

    func cacheNotificationsEnabled(for session: AgentSession) -> Bool {
        preferences.cacheNotificationsEnabled(for: session)
    }

    func cacheNotificationProfileEnabled(_ profile: CacheNotificationProfile) -> Bool {
        preferences.cacheNotificationProfiles.first(where: { $0.profile == profile })?.isEnabled ?? true
    }

    func cacheNotificationWarningSeconds(_ profile: CacheNotificationProfile) -> Int {
        preferences.cacheNotificationProfiles.first(where: { $0.profile == profile })?.warningSeconds
            ?? preferences.cacheWarningSeconds
    }

    func setCacheNotificationProfile(
        _ profile: CacheNotificationProfile,
        enabled: Bool? = nil,
        warningSeconds: Int? = nil
    ) {
        preferences.setCacheNotificationProfile(
            profile,
            isEnabled: enabled,
            warningSeconds: warningSeconds
        )
    }

    func cacheAlertDisposition(for session: AgentSession) -> CacheAlertDisposition? {
        preferences.cacheAlertDisposition(for: session)
    }

    func hasCacheNotificationRule(_ scope: CacheNotificationScope, for session: AgentSession) -> Bool {
        preferences.hasCacheNotificationRule(scope, for: session)
    }

    func setCacheNotificationsEnabled(_ enabled: Bool, for providerID: AgentProviderID) {
        let rule = CacheNotificationRule(scope: .provider, providerID: providerID, isEnabled: enabled)
        // A single assignment so the preference is persisted exactly once.
        preferences.cacheNotificationRules =
            preferences.cacheNotificationRules.filter { $0.id != rule.id } + [rule]
    }

    func setCacheNotificationsEnabled(_ enabled: Bool, for project: CacheNotificationProject) {
        preferences.setCacheNotificationRule(enabled: enabled, scope: .project, for: project.session)
    }

    func setCacheNotificationsEnabled(_ enabled: Bool, for session: AgentSession) {
        preferences.setCacheNotificationRule(enabled: enabled, scope: .session, for: session)
    }

    func clearCacheNotificationRule(for session: AgentSession) {
        preferences.clearCacheNotificationRule(scope: .session, for: session)
    }

    func acknowledgeCacheWarning(for session: AgentSession) {
        preferences.setCacheAlertDisposition(.acknowledged, for: session)
    }

    func ignoreCacheWarning(for session: AgentSession) {
        preferences.setCacheAlertDisposition(.ignoredForCurrentCache, for: session)
    }
}
