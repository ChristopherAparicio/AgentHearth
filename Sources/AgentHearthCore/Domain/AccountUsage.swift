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

    /// A weekly window scoped to one model. Providers increasingly bill some
    /// models against their own weekly allowance, and that scoped limit is
    /// often the binding one — so it deserves its own bar rather than being
    /// folded into the account-wide window.
    public struct ScopedWindow: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let window: Window
        public let isActive: Bool

        public init(id: String, label: String, window: Window, isActive: Bool) {
            self.id = id
            self.label = label
            self.window = window
            self.isActive = isActive
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    public let scopedWeekly: [ScopedWindow]
    public let fetchedAt: Date

    public init(
        fiveHour: Window?,
        sevenDay: Window?,
        scopedWeekly: [ScopedWindow] = [],
        fetchedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scopedWeekly = scopedWeekly
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
