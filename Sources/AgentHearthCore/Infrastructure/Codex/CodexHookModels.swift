import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct CodexHookEvent: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let eventName: String
    public let sessionID: String
    public let transcriptPath: String?
    public let workingDirectory: String?
    public let model: String?
    public let sentAt: Int64

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        eventName: String,
        sessionID: String,
        transcriptPath: String? = nil,
        workingDirectory: String? = nil,
        model: String? = nil,
        sentAt: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.eventName = eventName
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.workingDirectory = workingDirectory
        self.model = model
        self.sentAt = sentAt
    }
}

public enum CodexHookEventError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidSession

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported Codex hook schema: \(version)"
        case .invalidSession:
            "Codex hook event has no session identifier"
        }
    }
}
