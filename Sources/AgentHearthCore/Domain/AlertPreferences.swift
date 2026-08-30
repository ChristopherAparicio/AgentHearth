import Foundation

public struct UsageAlertThreshold: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var percentage: Int
    public var soundName: String

    public init(id: String, percentage: Int, soundName: String) {
        self.id = id
        self.percentage = min(max(percentage, 1), 100)
        self.soundName = soundName
    }
}

public struct AlertPreferences: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var sessionAttentionEnabled: Bool
    public var sessionCompletionEnabled: Bool
    public var cacheExpiryEnabled: Bool
    public var usageLimitEnabled: Bool
    public var cacheWarningSeconds: Int
    public var usageWarningFraction: Double
    public var usageAlertThresholds: [UsageAlertThreshold]
    public var cacheNotificationProfiles: [CacheNotificationProfilePreference]
    public var cacheNotificationRules: [CacheNotificationRule]
    public var cacheAlertStates: [CacheAlertState]

    public init(
        notificationsEnabled: Bool = true,
        sessionAttentionEnabled: Bool = true,
        sessionCompletionEnabled: Bool = true,
        cacheExpiryEnabled: Bool = true,
        usageLimitEnabled: Bool = true,
        cacheWarningSeconds: Int = 60,
        usageWarningFraction: Double = 0.80,
        usageAlertThresholds: [UsageAlertThreshold]? = nil,
        cacheNotificationProfiles: [CacheNotificationProfilePreference] = [],
        cacheNotificationRules: [CacheNotificationRule] = [],
        cacheAlertStates: [CacheAlertState] = []
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.sessionAttentionEnabled = sessionAttentionEnabled
        self.sessionCompletionEnabled = sessionCompletionEnabled
        self.cacheExpiryEnabled = cacheExpiryEnabled
        self.usageLimitEnabled = usageLimitEnabled
        self.cacheWarningSeconds = max(0, cacheWarningSeconds)
        self.usageWarningFraction = min(max(usageWarningFraction, 0), 1)
        self.usageAlertThresholds = usageAlertThresholds ?? [
            UsageAlertThreshold(id: "usage-80", percentage: 80, soundName: "Funk"),
            UsageAlertThreshold(id: "usage-90", percentage: 90, soundName: "Basso"),
            UsageAlertThreshold(id: "usage-95", percentage: 95, soundName: "Hero")
        ]
        self.cacheNotificationProfiles = cacheNotificationProfiles
        self.cacheNotificationRules = cacheNotificationRules
        self.cacheAlertStates = cacheAlertStates
    }

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, sessionAttentionEnabled, sessionCompletionEnabled
        case cacheExpiryEnabled, usageLimitEnabled, cacheWarningSeconds, usageWarningFraction
        case usageAlertThresholds, cacheNotificationProfiles
        case cacheNotificationRules, cacheAlertStates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        self.sessionAttentionEnabled = try container.decodeIfPresent(Bool.self, forKey: .sessionAttentionEnabled) ?? true
        self.sessionCompletionEnabled = try container.decodeIfPresent(Bool.self, forKey: .sessionCompletionEnabled) ?? true
        self.cacheExpiryEnabled = try container.decodeIfPresent(Bool.self, forKey: .cacheExpiryEnabled) ?? true
        self.usageLimitEnabled = try container.decodeIfPresent(Bool.self, forKey: .usageLimitEnabled) ?? true
        self.cacheWarningSeconds = max(0, try container.decodeIfPresent(Int.self, forKey: .cacheWarningSeconds) ?? 60)
        self.usageWarningFraction = min(max(try container.decodeIfPresent(Double.self, forKey: .usageWarningFraction) ?? 0.80, 0), 1)
        self.usageAlertThresholds = try container.decodeIfPresent([UsageAlertThreshold].self, forKey: .usageAlertThresholds) ?? [
            UsageAlertThreshold(id: "usage-legacy", percentage: Int(self.usageWarningFraction * 100), soundName: "Funk")
        ]
        self.cacheNotificationProfiles = try container.decodeIfPresent([CacheNotificationProfilePreference].self, forKey: .cacheNotificationProfiles) ?? []
        self.cacheNotificationRules = try container.decodeIfPresent([CacheNotificationRule].self, forKey: .cacheNotificationRules) ?? []
        self.cacheAlertStates = try container.decodeIfPresent([CacheAlertState].self, forKey: .cacheAlertStates) ?? []
    }

    public func cacheNotificationsEnabled(for session: AgentSession) -> Bool {
        guard cacheExpiryEnabled else { return false }
        if let preference = cacheNotificationProfiles.first(where: { $0.profile == CacheNotificationProfile(session: session) }),
           !preference.isEnabled {
            return false
        }
        let scopeOrder: [CacheNotificationScope] = [.session, .project, .provider]
        for scope in scopeOrder {
            if let rule = cacheNotificationRules.first(where: { $0.scope == scope && $0.matches(session) }) {
                return rule.isEnabled
            }
        }
        return true
    }

    public func cacheAlertDisposition(for session: AgentSession) -> CacheAlertDisposition? {
        cacheAlertStates.first(where: { $0.matchesCurrentCache(of: session) })?.disposition
    }

    public func hasCacheNotificationRule(
        _ scope: CacheNotificationScope,
        for session: AgentSession
    ) -> Bool {
        cacheNotificationRules.contains { $0.scope == scope && $0.matches(session) }
    }

    public func shouldNotifyCacheExpiry(for session: AgentSession) -> Bool {
        guard cacheNotificationsEnabled(for: session) else { return false }
        return cacheAlertDisposition(for: session) != .ignoredForCurrentCache
    }

    public func cacheWarningSeconds(for session: AgentSession) -> Int {
        cacheNotificationProfiles
            .first(where: { $0.profile == CacheNotificationProfile(session: session) })?
            .warningSeconds ?? cacheWarningSeconds
    }

    public func usageThresholdCrossed(from previous: Double, to current: Double) -> UsageAlertThreshold? {
        usageAlertThresholds
            .filter { previous < Double($0.percentage) / 100 && current >= Double($0.percentage) / 100 }
            .max { $0.percentage < $1.percentage }
    }

    public mutating func setCacheNotificationProfile(
        _ profile: CacheNotificationProfile,
        isEnabled: Bool? = nil,
        warningSeconds: Int? = nil
    ) {
        let current = cacheNotificationProfiles.first(where: { $0.profile == profile })
            ?? CacheNotificationProfilePreference(profile: profile, warningSeconds: cacheWarningSeconds)
        let updated = CacheNotificationProfilePreference(
            profile: profile,
            isEnabled: isEnabled ?? current.isEnabled,
            warningSeconds: warningSeconds ?? current.warningSeconds
        )
        cacheNotificationProfiles.removeAll { $0.profile == profile }
        cacheNotificationProfiles.append(updated)
    }

    public mutating func setCacheNotificationRule(
        enabled: Bool,
        scope: CacheNotificationScope,
        for session: AgentSession
    ) {
        let rule = switch scope {
        case .provider:
            CacheNotificationRule(scope: .provider, providerID: session.providerID, isEnabled: enabled)
        case .project:
            CacheNotificationRule(
                scope: .project,
                providerID: session.providerID,
                hostID: session.host.id,
                projectName: session.projectName,
                isEnabled: enabled
            )
        case .session:
            CacheNotificationRule(
                scope: .session,
                providerID: session.providerID,
                hostID: session.host.id,
                sessionID: session.id,
                isEnabled: enabled
            )
        }
        cacheNotificationRules.removeAll { $0.id == rule.id }
        cacheNotificationRules.append(rule)
    }

    public mutating func clearCacheNotificationRule(
        scope: CacheNotificationScope,
        for session: AgentSession
    ) {
        let probe = switch scope {
        case .provider:
            CacheNotificationRule(scope: .provider, providerID: session.providerID, isEnabled: true)
        case .project:
            CacheNotificationRule(scope: .project, providerID: session.providerID, hostID: session.host.id, projectName: session.projectName, isEnabled: true)
        case .session:
            CacheNotificationRule(scope: .session, providerID: session.providerID, hostID: session.host.id, sessionID: session.id, isEnabled: true)
        }
        cacheNotificationRules.removeAll { $0.id == probe.id }
    }

    public mutating func setCacheAlertDisposition(
        _ disposition: CacheAlertDisposition,
        for session: AgentSession
    ) {
        let state = CacheAlertState(
            providerID: session.providerID,
            hostID: session.host.id,
            sessionID: session.id,
            cacheConfirmedAt: session.cache.lastConfirmedAt,
            disposition: disposition
        )
        cacheAlertStates.removeAll { $0.id == state.id }
        cacheAlertStates.append(state)
    }

    public mutating func pruneCacheAlertStates(using sessions: [AgentSession]) {
        cacheAlertStates.removeAll { state in
            guard let session = sessions.first(where: {
                $0.providerID == state.providerID && $0.host.id == state.hostID && $0.id == state.sessionID
            }) else { return true }
            return !state.matchesCurrentCache(of: session)
        }
    }
}
