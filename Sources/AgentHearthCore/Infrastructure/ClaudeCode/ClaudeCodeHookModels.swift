import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct ClaudeCodeHookEvent: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let eventName: String
    public let sessionID: String
    public let transcriptPath: String?
    public let workingDirectory: String?
    public let model: String?
    public let notificationType: String?
    public let sentAt: Int64

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        eventName: String,
        sessionID: String,
        transcriptPath: String? = nil,
        workingDirectory: String? = nil,
        model: String? = nil,
        notificationType: String? = nil,
        sentAt: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.eventName = eventName
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.workingDirectory = workingDirectory
        self.model = model
        self.notificationType = notificationType
        self.sentAt = sentAt
    }
}

public enum ClaudeCodeHookEventError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidSession

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported Claude Code hook schema: \(version)"
        case .invalidSession:
            "Claude Code hook event has no session identifier"
        }
    }
}

public struct ClaudeCodeStatusEvent: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: String
    public let workingDirectory: String?
    public let model: String?
    public let fiveHour: ClaudeCodeRateLimitWindow?
    public let sevenDay: ClaudeCodeRateLimitWindow?
    public let sentAt: Int64

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        sessionID: String,
        workingDirectory: String? = nil,
        model: String? = nil,
        fiveHour: ClaudeCodeRateLimitWindow? = nil,
        sevenDay: ClaudeCodeRateLimitWindow? = nil,
        sentAt: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.model = model
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sentAt = sentAt
    }
}

public struct ClaudeCodeRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: TimeInterval?

    public init(usedPercentage: Double, resetsAt: TimeInterval? = nil) {
        self.usedPercentage = min(max(usedPercentage, 0), 100)
        self.resetsAt = resetsAt
    }
}
