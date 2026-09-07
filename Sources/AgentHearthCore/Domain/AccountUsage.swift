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

    /// A weekly window that applies to one scope only (Anthropic reports a
    /// per-model weekly limit next to the global one). `isActive` marks the
    /// limit the provider currently considers binding.
    public struct ScopedWindow: Equatable, Sendable, Identifiable {
        /// Stable identifier derived from the scope, e.g. `fable`.
        public let id: String
        /// Display name of the scope, e.g. `Fable`.
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

    /// The same usage without the per-scope weekly windows (user preference).
    public func withoutScopedWeekly() -> AccountUsage {
        AccountUsage(fiveHour: fiveHour, sevenDay: sevenDay, scopedWeekly: [], fetchedAt: fetchedAt)
    }
}

/// Outcome of asking a provider's service for account usage, so consumers can
/// distinguish credential problems (user-fixable) from transient failures.
///
/// The three credential cases are kept apart because they need three different
/// gestures from the user: signing in again, letting the CLI refresh itself,
/// and approving a Keychain dialog. Collapsing them into one "refresh your
/// sign-in" message sends people to fix the wrong thing.
public enum AccountUsageFetchOutcome: Sendable {
    case usage(AccountUsage)
    /// No usable sign-in exists: either nothing is stored at all, or every
    /// stored record is a logged-out husk — Claude Code blanks the token
    /// strings on logout — with no live refresh token to revive it. Only
    /// signing in again fixes this.
    case signedOut
    /// A stored access token has lapsed, but a live refresh token means the
    /// CLI can mint a new one by itself the next time it runs.
    case tokenExpired
    /// macOS refused to hand over the Keychain data: the consent dialog was
    /// declined, or could not be shown. The sign-in itself may be perfectly
    /// fine.
    case keychainAccessDenied
    case failed(String)
}
