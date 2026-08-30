import AgentHearthApplication
import AgentHearthDomain
import Foundation

public enum OpenCodeReportedStatus: String, Codable, Sendable {
    case working
    case waitingForApproval
    case idle
    case stuck
    case failed
}

public struct OpenCodeCacheReport: Codable, Equatable, Sendable {
    public let temperature: CacheTemperature
    public let remainingSeconds: Int?
    public let ttlSeconds: Int?
    public let cachedReadTokens: Int
    public let cacheWriteTokens: Int
    public let hitCount: Int
    public let avoidableMissCount: Int
    public let expectedColdStartCount: Int
    public let unknownCount: Int

    public init(
        temperature: CacheTemperature,
        remainingSeconds: Int? = nil,
        ttlSeconds: Int? = nil,
        cachedReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        hitCount: Int = 0,
        avoidableMissCount: Int = 0,
        expectedColdStartCount: Int = 0,
        unknownCount: Int = 0
    ) {
        self.temperature = temperature
        self.remainingSeconds = remainingSeconds
        self.ttlSeconds = ttlSeconds
        self.cachedReadTokens = max(0, cachedReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.hitCount = max(0, hitCount)
        self.avoidableMissCount = max(0, avoidableMissCount)
        self.expectedColdStartCount = max(0, expectedColdStartCount)
        self.unknownCount = max(0, unknownCount)
    }
}

public struct OpenCodeSessionReport: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let projectPath: String
    public let model: String?
    public let provider: String?
    public let status: OpenCodeReportedStatus
    public let lastActivityAt: Int64
    public let cache: OpenCodeCacheReport

    public init(
        id: String,
        title: String,
        projectPath: String,
        model: String? = nil,
        provider: String? = nil,
        status: OpenCodeReportedStatus,
        lastActivityAt: Int64,
        cache: OpenCodeCacheReport
    ) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.model = model
        self.provider = provider
        self.status = status
        self.lastActivityAt = lastActivityAt
        self.cache = cache
    }
}

public struct OpenCodePushPayload: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let pluginVersion: String
    public let instance: String
    public let sentAt: Int64
    public let sessions: [OpenCodeSessionReport]

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        pluginVersion: String,
        instance: String,
        sentAt: Int64,
        sessions: [OpenCodeSessionReport]
    ) {
        self.schemaVersion = schemaVersion
        self.pluginVersion = pluginVersion
        self.instance = instance
        self.sentAt = sentAt
        self.sessions = sessions
    }
}

public enum OpenCodePayloadError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidInstance

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported OpenCode connector schema: \(version)"
        case .invalidInstance:
            "OpenCode connector payload has no instance identifier"
        }
    }
}
