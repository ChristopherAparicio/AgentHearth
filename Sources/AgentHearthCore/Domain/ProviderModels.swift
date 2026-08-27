import Foundation

public enum AgentProviderID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claudeCode
    case openCode

    public var id: String { rawValue }
}

/// The surface used when AgentHearth opens a provider session. Native provider
/// apps are only available for sessions observed on this Mac; remote sessions
/// always need an SSH terminal to resume on their source machine.
public enum SessionOpenDestination: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case providerApp
    case terminal

    public var id: String { rawValue }
}

/// Persisted per-provider session opening choices. Terminal is the default
/// because it is the only public route that resumes the observed CLI session
/// exactly; provider apps can be opened as a convenience surface.
public struct SessionOpenPreferences: Codable, Equatable, Sendable {
    public var codex: SessionOpenDestination
    public var claudeCode: SessionOpenDestination
    public var openCode: SessionOpenDestination

    public init(
        codex: SessionOpenDestination = .terminal,
        claudeCode: SessionOpenDestination = .terminal,
        openCode: SessionOpenDestination = .terminal
    ) {
        self.codex = codex
        self.claudeCode = claudeCode
        self.openCode = openCode
    }

    public func destination(for providerID: AgentProviderID) -> SessionOpenDestination {
        switch providerID {
        case .codex: codex
        case .claudeCode: claudeCode
        case .openCode: openCode
        }
    }

    public mutating func setDestination(_ destination: SessionOpenDestination, for providerID: AgentProviderID) {
        switch providerID {
        case .codex: codex = destination
        case .claudeCode: claudeCode = destination
        case .openCode: openCode = destination
        }
    }

    public func effectiveDestination(for target: SessionTarget) -> SessionOpenDestination {
        target.host.kind == .local ? destination(for: target.providerID) : .terminal
    }
}

public enum ProviderDataSourceMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case automatic
    case localOnly
    case realtimeOnly

    public var id: String { rawValue }

    public var usesLocalData: Bool {
        self != .realtimeOnly
    }

    public var usesRealtimeData: Bool {
        self != .localOnly
    }
}

public enum AgentHostKind: String, Codable, Hashable, Sendable {
    case local
    case ssh
}

/// Identifies the computer that owns a provider session. Credentials are never
/// stored here: SSH destinations resolve through the user's existing SSH config.
public struct AgentHost: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: AgentHostKind
    public let sshDestination: String?

    public init(
        id: String,
        displayName: String,
        kind: AgentHostKind,
        sshDestination: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.sshDestination = sshDestination
    }

    public static let local = AgentHost(
        id: "local",
        displayName: "This Mac",
        kind: .local
    )
}

public struct RemoteHostConfiguration: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var displayName: String
    public var sshDestination: String
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        sshDestination: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.sshDestination = sshDestination
        self.isEnabled = isEnabled
    }

    public var host: AgentHost {
        AgentHost(
            id: id,
            displayName: displayName,
            kind: .ssh,
            sshDestination: sshDestination
        )
    }
}

/// A concrete provider runtime observed by AgentHearth. A host can run several
/// runtimes of the same provider, for example two OpenCode HTTP servers.
public struct AgentSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A loopback OpenCode server. Remote servers are reached through the existing
/// SSH host; AgentHearth never requires exposing the OpenCode port publicly.
public struct OpenCodeServerConfiguration: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var displayName: String
    public var hostID: String
    public var port: Int
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        hostID: String = AgentHost.local.id,
        port: Int = 4096,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.hostID = hostID
        self.port = port
        self.isEnabled = isEnabled
    }

    public var source: AgentSource {
        AgentSource(id: id, displayName: displayName)
    }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case working
    case waitingForInput
    case waitingForApproval
    case idle
    case stuck
    case completed
    case failed

    public var requiresAttention: Bool {
        switch self {
        case .waitingForInput, .waitingForApproval, .stuck, .failed:
            true
        case .working, .idle, .completed:
            false
        }
    }

    public var preventsIdleSystemSleep: Bool {
        switch self {
        case .working, .waitingForApproval:
            true
        case .waitingForInput, .idle, .stuck, .completed, .failed:
            false
        }
    }
}

public enum CacheTemperature: String, Codable, Sendable {
    case warm
    case expiring
    case cold
    case unknown
}

public enum CacheConfidence: String, Codable, Sendable {
    case exactPolicy
    case observed
    case inferred
    case unknown
}

public struct CacheSnapshot: Codable, Equatable, Sendable {
    public let temperature: CacheTemperature
    public let remainingSeconds: Int?
    public let ttlSeconds: Int?
    /// Input tokens measured for the latest completed provider turn. This is
    /// intentionally separate from the cache temperature: a cold cache can
    /// still have been largely reused by the preceding turn.
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let lastConfirmedAt: Date?
    public let confidence: CacheConfidence
    public let reason: String?

    public init(
        temperature: CacheTemperature,
        remainingSeconds: Int? = nil,
        ttlSeconds: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        lastConfirmedAt: Date? = nil,
        confidence: CacheConfidence = .unknown,
        reason: String? = nil
    ) {
        self.temperature = temperature
        self.remainingSeconds = remainingSeconds
        self.ttlSeconds = ttlSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedReadTokens = cachedReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.lastConfirmedAt = lastConfirmedAt
        self.confidence = confidence
        self.reason = reason
    }

    public static let unknown = CacheSnapshot(temperature: .unknown)

    /// Fraction of this turn's prompt served from cache. The provider's raw
    /// `inputTokens` counts only fresh, uncached tokens, so the denominator is
    /// the full prompt: fresh + cache-read + cache-creation. (Dividing by
    /// `inputTokens` alone reported ~100% for every session.)
    public var cacheReuseRate: Double? {
        guard let inputTokens, let cachedReadTokens else { return nil }
        let total = max(0, inputTokens) + max(0, cachedReadTokens) + max(0, cacheWriteTokens ?? 0)
        guard total > 0 else { return nil }
        return min(1, Double(max(0, cachedReadTokens)) / Double(total))
    }

    /// Prompt tokens that were processed fresh this turn (never served from
    /// cache): the raw input plus any tokens written to the cache.
    public var uncachedInputTokens: Int? {
        guard inputTokens != nil || cacheWriteTokens != nil else { return nil }
        return max(0, inputTokens ?? 0) + max(0, cacheWriteTokens ?? 0)
    }
}

public struct UsageWindow: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedFraction: Double
    public let resetsAt: Date?
    public let measuredAt: Date
    public let host: AgentHost

    public init(
        id: String,
        label: String,
        usedFraction: Double,
        resetsAt: Date? = nil,
        measuredAt: Date = .now,
        host: AgentHost = .local
    ) {
        self.id = id
        self.label = label
        self.usedFraction = min(max(usedFraction, 0), 1)
        self.resetsAt = resetsAt
        self.measuredAt = measuredAt
        self.host = host
    }
}

public struct SessionTarget: Codable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let sessionID: String
    public let workingDirectory: URL?
    public let host: AgentHost

    public init(
        providerID: AgentProviderID,
        sessionID: String,
        workingDirectory: URL? = nil,
        host: AgentHost = .local
    ) {
        self.providerID = providerID
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.host = host
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let providerID: AgentProviderID
    public let title: String
    public let projectName: String?
    public let model: String?
    public let status: SessionStatus
    public let lastActivityAt: Date
    public let cache: CacheSnapshot
    public let cacheHealth: CacheHealthSnapshot?
    public let target: SessionTarget?
    public let host: AgentHost
    public let source: AgentSource?

    public init(
        id: String,
        providerID: AgentProviderID,
        title: String,
        projectName: String? = nil,
        model: String? = nil,
        status: SessionStatus,
        lastActivityAt: Date,
        cache: CacheSnapshot = .unknown,
        cacheHealth: CacheHealthSnapshot? = nil,
        target: SessionTarget? = nil,
        host: AgentHost = .local,
        source: AgentSource? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.projectName = projectName
        self.model = model
        self.status = status
        self.lastActivityAt = lastActivityAt
        self.cache = cache
        self.cacheHealth = cacheHealth
        self.target = target
        self.host = host
        self.source = source
    }
}

public enum ProviderConnectionState: Equatable, Sendable {
    case connected
    case degraded(message: String)
    case unavailable
}

public struct ProviderSnapshot: Identifiable, Equatable, Sendable {
    public let id: AgentProviderID
    public let connectionState: ProviderConnectionState
    public let sessions: [AgentSession]
    public let usageWindows: [UsageWindow]
    public let updatedAt: Date

    public init(
        id: AgentProviderID,
        connectionState: ProviderConnectionState,
        sessions: [AgentSession],
        usageWindows: [UsageWindow],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.connectionState = connectionState
        self.sessions = sessions
        self.usageWindows = usageWindows
        self.updatedAt = updatedAt
    }
}
