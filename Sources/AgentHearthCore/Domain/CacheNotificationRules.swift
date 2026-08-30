import Foundation

public enum CacheNotificationScope: String, Codable, CaseIterable, Sendable {
    case provider
    case project
    case session
}

/// Cache TTLs are provider policies, not an OpenCode policy. OpenCode sessions
/// are classified from their model identifier so an OpenAI-backed session is
/// never configured as if it were a Claude cache (or the reverse).
public enum CacheNotificationProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claudeCode
    case openCodeOpenAI
    case openCodeAnthropic
    case openCodeOther

    public var id: String { rawValue }

    public init(session: AgentSession) {
        switch session.providerID {
        case .codex:
            self = .codex
        case .claudeCode:
            self = .claudeCode
        case .openCode:
            switch ModelFamily(modelID: session.model) {
            case .anthropic:
                self = .openCodeAnthropic
            case .openAI:
                self = .openCodeOpenAI
            case .other:
                self = .openCodeOther
            }
        }
    }
}

public struct CacheNotificationProfilePreference: Identifiable, Codable, Equatable, Sendable {
    public let profile: CacheNotificationProfile
    public var isEnabled: Bool
    public var warningSeconds: Int

    public var id: String { profile.rawValue }

    public init(profile: CacheNotificationProfile, isEnabled: Bool = true, warningSeconds: Int) {
        self.profile = profile
        self.isEnabled = isEnabled
        self.warningSeconds = max(0, warningSeconds)
    }
}

/// A local exception to the default cache-notification policy. More specific
/// scopes win: a session override takes precedence over a project, then a
/// provider override. Projects and sessions are host-scoped to avoid matching
/// unrelated remote workspaces with the same name.
public struct CacheNotificationRule: Identifiable, Codable, Equatable, Sendable {
    public let scope: CacheNotificationScope
    public let providerID: AgentProviderID
    public let hostID: String?
    public let projectName: String?
    public let sessionID: String?
    public var isEnabled: Bool

    public var id: String {
        [
            scope.rawValue,
            providerID.rawValue,
            hostID ?? "",
            projectName ?? "",
            sessionID ?? ""
        ].joined(separator: "|")
    }

    public init(
        scope: CacheNotificationScope,
        providerID: AgentProviderID,
        hostID: String? = nil,
        projectName: String? = nil,
        sessionID: String? = nil,
        isEnabled: Bool
    ) {
        self.scope = scope
        self.providerID = providerID
        self.hostID = hostID
        self.projectName = projectName
        self.sessionID = sessionID
        self.isEnabled = isEnabled
    }

    func matches(_ session: AgentSession) -> Bool {
        guard providerID == session.providerID else { return false }
        switch scope {
        case .provider:
            return true
        case .project:
            return hostID == session.host.id && projectName == session.projectName
        case .session:
            return hostID == session.host.id && sessionID == session.id
        }
    }
}

public enum CacheAlertDisposition: String, Codable, Equatable, Sendable {
    case acknowledged
    case ignoredForCurrentCache
}

/// UI state for a cache warning. It is keyed to the provider's cache evidence
/// so it disappears naturally when that session creates or reads a newer cache.
public struct CacheAlertState: Identifiable, Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let hostID: String
    public let sessionID: String
    public let cacheConfirmedAt: Date?
    public var disposition: CacheAlertDisposition

    public var id: String { "\(providerID.rawValue)|\(hostID)|\(sessionID)" }

    public init(
        providerID: AgentProviderID,
        hostID: String,
        sessionID: String,
        cacheConfirmedAt: Date?,
        disposition: CacheAlertDisposition
    ) {
        self.providerID = providerID
        self.hostID = hostID
        self.sessionID = sessionID
        self.cacheConfirmedAt = cacheConfirmedAt
        self.disposition = disposition
    }

    func matchesCurrentCache(of session: AgentSession) -> Bool {
        providerID == session.providerID
            && hostID == session.host.id
            && sessionID == session.id
            && cacheConfirmedAt == session.cache.lastConfirmedAt
    }
}
