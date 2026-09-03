import Foundation

public struct AlertSourceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let agentHearth = AlertSourceID(rawValue: "agenthearth")
    public static let ai5 = AlertSourceID(rawValue: "ai5")
}

public enum AlertSeverity: Int, Codable, Comparable, Sendable {
    case information = 0
    case warning = 1
    case error = 2
    case critical = 3

    public static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AlertStatus: String, Codable, Sendable {
    case open
    case acknowledged
    case snoozed
    case resolved
}

public struct AgentAlert: Identifiable, Codable, Equatable, Sendable {
    /// Unique per emission, not per logical alert: detectors mint a fresh id
    /// for every delivery, and MacNotificationCenter reuses it verbatim as the
    /// UNNotificationRequest identifier, where a repeated id would silently
    /// replace the pending notification instead of presenting a new one.
    /// `fingerprint` — stable across emissions of the same condition — is the
    /// identity key for deduplication; never dedup on `id`.
    public let id: String
    public let sourceID: AlertSourceID
    public let type: String
    public let severity: AlertSeverity
    public let title: String
    public let summary: String
    public let status: AlertStatus
    public let occurredAt: Date
    public let sessionTarget: SessionTarget?
    public let fingerprint: String?
    public let soundName: String?

    public init(
        id: String,
        sourceID: AlertSourceID,
        type: String,
        severity: AlertSeverity,
        title: String,
        summary: String,
        status: AlertStatus = .open,
        occurredAt: Date = .now,
        sessionTarget: SessionTarget? = nil,
        fingerprint: String? = nil,
        soundName: String? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.type = type
        self.severity = severity
        self.title = title
        self.summary = summary
        self.status = status
        self.occurredAt = occurredAt
        self.sessionTarget = sessionTarget
        self.fingerprint = fingerprint
        self.soundName = soundName
    }
}
