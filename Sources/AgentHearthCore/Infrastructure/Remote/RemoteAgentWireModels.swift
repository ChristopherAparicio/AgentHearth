import AgentHearthApplication
import AgentHearthDomain
import Foundation

struct RemoteAgentEnvelope: Decodable, Sendable {
    let schemaVersion: Int
    let provider: AgentProviderID
    let available: Bool
    let message: String?
    let sessions: [RemoteAgentSession]
    let usageWindows: [RemoteAgentUsageWindow]
    let updatedAt: Int64
}

struct RemoteAgentSession: Decodable, Sendable {
    let id: String
    let title: String
    let projectName: String?
    let model: String?
    let status: SessionStatus
    let lastActivityAt: Int64
    let cache: RemoteAgentCache
    let cacheHealth: RemoteAgentCacheHealth?
    let workingDirectory: String?
}

struct RemoteAgentCache: Decodable, Sendable {
    let temperature: CacheTemperature
    let remainingSeconds: Int?
    let ttlSeconds: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedReadTokens: Int?
    let cacheWriteTokens: Int?
    let lastConfirmedAt: Int64?
    let confidence: CacheConfidence
    let reason: String?
}

struct RemoteAgentCacheHealth: Decodable, Sendable {
    let hitCount: Int
    let avoidableMissCount: Int
    let expectedColdStartCount: Int
    let unknownCount: Int
    let measuredAt: Int64
    let observedInputTokens: Int?
    let cachedInputTokens: Int?
}

struct RemoteAgentUsageWindow: Decodable, Sendable {
    let id: String
    let label: String
    let usedFraction: Double
    let resetsAt: Int64?
    let measuredAt: Int64
}

struct RemoteAgentHealth: Decodable, Sendable {
    let schemaVersion: Int
    let service: String
    let status: String
    let version: String
}

struct RemoteAgentHistoryEnvelope: Decodable, Sendable {
    let schemaVersion: Int
    let nextCursor: Int64
    let events: [RemoteAgentHistoryEvent]
}

struct RemoteAgentHistoryEvent: Decodable, Sendable {
    let id: Int64
    let provider: AgentProviderID
    let sessionId: String
    let title: String
    let model: String?
    let occurredAt: Int64
    let hitCount: Int
    let missCount: Int
    let coldStartCount: Int
    let unknownCount: Int
    let currentHitCount: Int
    let currentMissCount: Int
    let currentColdStartCount: Int
    let currentUnknownCount: Int
}

extension JSONDecoder {
    static func agentHearthRemote() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
