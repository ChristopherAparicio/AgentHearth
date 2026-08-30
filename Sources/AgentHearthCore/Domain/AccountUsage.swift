import Foundation

/// Authoritative rolling-window account usage reported by a provider's own
/// service (e.g. Anthropic's 5h/7d windows), including reset timestamps that
/// local journals never record.
public struct AccountUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let utilizationFraction: Double
        public let resetsAt: Date?

        public init(utilizationFraction: Double, resetsAt: Date?) {
            self.utilizationFraction = min(1, max(0, utilizationFraction))
            self.resetsAt = resetsAt
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    public let fetchedAt: Date

    public init(fiveHour: Window?, sevenDay: Window?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }
}

/// Outcome of asking a provider's service for account usage, so consumers can
/// distinguish credential problems (user-fixable) from transient failures.
public enum AccountUsageFetchOutcome: Sendable {
    case usage(AccountUsage)
    case tokenMissing
    case tokenExpired
    case failed(String)
}
