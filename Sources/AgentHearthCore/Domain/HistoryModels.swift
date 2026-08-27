import Foundation

public enum HistoryRetention: Int, CaseIterable, Codable, Identifiable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365

    public var id: Int { rawValue }
}

public struct CacheHistoryBucket: Identifiable, Equatable, Sendable, CacheActivityAggregate {
    public let day: Date
    public let turnCount: Int
    public let hitCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int

    public var id: Date { day }

    public init(
        day: Date,
        turnCount: Int,
        hitCount: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) {
        self.day = day
        self.turnCount = turnCount
        self.hitCount = hitCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

public struct SessionHistorySummary: Identifiable, Equatable, Sendable, CacheActivityAggregate {
    public let id: String
    public let title: String
    public let providerID: AgentProviderID
    public let hostName: String
    public let sourceName: String?
    public let hitCount: Int
    public let turnCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let lastSeenAt: Date

    public init(
        id: String,
        title: String,
        providerID: AgentProviderID,
        hostName: String,
        sourceName: String?,
        hitCount: Int,
        turnCount: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        lastSeenAt: Date
    ) {
        self.id = id
        self.title = title
        self.providerID = providerID
        self.hostName = hostName
        self.sourceName = sourceName
        self.hitCount = hitCount
        self.turnCount = turnCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.lastSeenAt = lastSeenAt
    }
}

public struct ProjectHistorySummary: Identifiable, Equatable, Sendable, CacheActivityAggregate {
    public let projectName: String
    public let turnCount: Int
    public let hitCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int

    public var id: String { projectName }

    public init(
        projectName: String,
        turnCount: Int,
        hitCount: Int,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) {
        self.projectName = projectName
        self.turnCount = turnCount
        self.hitCount = hitCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

public struct HistoryDashboardSnapshot: Equatable, Sendable, CacheActivityAggregate {
    public let startsAt: Date
    public let endsAt: Date
    public let buckets: [CacheHistoryBucket]
    public let sessions: [SessionHistorySummary]
    public let projects: [ProjectHistorySummary]
    public let storageBytes: Int64

    public init(
        startsAt: Date,
        endsAt: Date,
        buckets: [CacheHistoryBucket],
        sessions: [SessionHistorySummary],
        projects: [ProjectHistorySummary],
        storageBytes: Int64
    ) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.buckets = buckets
        self.sessions = sessions
        self.projects = projects
        self.storageBytes = storageBytes
    }

    public var turnCount: Int { buckets.reduce(0) { $0 + $1.turnCount } }
    public var hitCount: Int { buckets.reduce(0) { $0 + $1.hitCount } }
    public var inputTokens: Int { buckets.reduce(0) { $0 + $1.inputTokens } }
    public var cachedInputTokens: Int { buckets.reduce(0) { $0 + $1.cachedInputTokens } }
    public var outputTokens: Int { buckets.reduce(0) { $0 + $1.outputTokens } }

    public static let empty = HistoryDashboardSnapshot(
        startsAt: .now,
        endsAt: .now,
        buckets: [],
        sessions: [],
        projects: [],
        storageBytes: 0
    )
}

/// A normalized cache-counter delta produced by a remote AgentHearth collector.
/// The stable external ID makes reconnects and retries idempotent.
public struct CacheHistoryImportEvent: Equatable, Sendable {
    public let externalID: String
    public let sessionKey: String
    public let sessionID: String
    public let providerID: AgentProviderID
    public let hostName: String
    public let sourceName: String?
    public let title: String
    public let model: String?
    public let occurredAt: Date
    public let hitCount: Int
    public let missCount: Int
    public let coldStartCount: Int
    public let unknownCount: Int
    public let currentHitCount: Int
    public let currentMissCount: Int
    public let currentColdStartCount: Int
    public let currentUnknownCount: Int

    public init(
        externalID: String,
        sessionKey: String,
        sessionID: String,
        providerID: AgentProviderID,
        hostName: String,
        sourceName: String? = nil,
        title: String,
        model: String? = nil,
        occurredAt: Date,
        hitCount: Int,
        missCount: Int,
        coldStartCount: Int,
        unknownCount: Int,
        currentHitCount: Int,
        currentMissCount: Int,
        currentColdStartCount: Int,
        currentUnknownCount: Int
    ) {
        self.externalID = externalID
        self.sessionKey = sessionKey
        self.sessionID = sessionID
        self.providerID = providerID
        self.hostName = hostName
        self.sourceName = sourceName
        self.title = title
        self.model = model
        self.occurredAt = occurredAt
        self.hitCount = max(0, hitCount)
        self.missCount = max(0, missCount)
        self.coldStartCount = max(0, coldStartCount)
        self.unknownCount = max(0, unknownCount)
        self.currentHitCount = max(0, currentHitCount)
        self.currentMissCount = max(0, currentMissCount)
        self.currentColdStartCount = max(0, currentColdStartCount)
        self.currentUnknownCount = max(0, currentUnknownCount)
    }
}
