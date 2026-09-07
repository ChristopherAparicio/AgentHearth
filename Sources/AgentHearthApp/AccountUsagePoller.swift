import AgentHearthCore
import AppKit
import Foundation
import Observation

/// Abstracts the Anthropic account-usage fetch so `AccountUsagePoller` can be
/// exercised with a fake instead of the Keychain-backed fetcher.
protocol AccountUsageFetching: Sendable {
    func fetch() async -> AccountUsageFetchOutcome
}

extension ClaudeAccountUsageFetcher: AccountUsageFetching {}

/// The single gesture that will bring reset times back. Three cases rather than
/// one because they call for opposite actions, and the wrong advice here is
/// worse than none: telling someone to "open Claude Code" when their account is
/// signed out sends them to a button that cannot possibly help.
enum AccountUsageRemedy: Equatable {
    /// No usable sign-in anywhere: only an interactive `claude auth login` helps.
    case signIn
    /// A lapsed access token with a live refresh token behind it — running the
    /// CLI once is enough, it refreshes on launch.
    case refreshToken
    /// macOS refused the Keychain read; the sign-in itself may be fine.
    case allowKeychainAccess
}

/// Owns the opt-in Anthropic account-usage polling: the enablement
/// preference, the user-facing fetch status, and the backoff schedule.
/// Successful fetches are handed to the injected `ingest` closure, which the
/// composition root wires into `ProviderMonitor`.
@MainActor
@Observable
final class AccountUsagePoller {
    private let fetcher: any AccountUsageFetching
    private let preferences: PreferencesStore

    /// Wired by the composition root: receives fetched usage (or nil when the
    /// feature is switched off) for injection into the Claude connector.
    @ObservationIgnored var ingest: (AccountUsage?) async -> Void = { _ in }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            preferences.claudeAccountUsageEnabled = isEnabled
        }
    }
    var status: String?
    /// Set when the last fetch failed on credentials, naming what the user has
    /// to do. Nil while usage is flowing, and after a merely transient failure.
    private(set) var remedy: AccountUsageRemedy?
    private var nextFetchAt: Date = .distantPast
    /// While a sign-in the user just started is still plausibly in flight,
    /// credential failures retry in seconds rather than minutes — a half-hour
    /// backoff would strand someone who finished logging in two minutes ago.
    private var signInGraceUntil: Date = .distantPast
    /// The last successful fetch, kept so toggling the scoped-limits
    /// preference re-applies immediately without another network call.
    private var lastUsage: AccountUsage?

    /// Whether per-model weekly limits are passed on to the connector.
    var showsScopedWeeklyLimits: Bool {
        didSet {
            guard showsScopedWeeklyLimits != oldValue else { return }
            preferences.showsClaudeScopedWeeklyLimits = showsScopedWeeklyLimits
            if let lastUsage, isEnabled {
                Task { await ingest(applyingPreferences(to: lastUsage)) }
            }
        }
    }

    /// Names of the per-model limits in the last fetch, for the Settings caption.
    var scopedWeeklyLimitLabels: [String] {
        lastUsage?.scopedWeekly.map(\.label) ?? []
    }

    private func applyingPreferences(to usage: AccountUsage) -> AccountUsage {
        showsScopedWeeklyLimits ? usage : usage.withoutScopedWeekly()
    }

    /// Forgets the backoff so the next refresh fetches immediately.
    func retryNow() {
        guard isEnabled else { return }
        nextFetchAt = .distantPast
    }

    /// After the user launched Claude Code or its sign-in: fetch again shortly,
    /// and keep retrying quickly for a few minutes so a login that takes a
    /// browser round-trip is picked up as soon as it lands.
    func expectSignInRefresh() {
        guard isEnabled else { return }
        let now = Date()
        nextFetchAt = now.addingTimeInterval(30)
        signInGraceUntil = now.addingTimeInterval(5 * 60)
        status = "Waiting for the Claude sign-in to complete…"
    }

    init(fetcher: any AccountUsageFetching, preferences: PreferencesStore) {
        self.fetcher = fetcher
        self.preferences = preferences
        self.isEnabled = preferences.claudeAccountUsageEnabled
        self.showsScopedWeeklyLimits = preferences.showsClaudeScopedWeeklyLimits
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            nextFetchAt = .distantPast
            // Fetch right away rather than on the next poll: reading the token
            // makes macOS ask the user to allow Keychain access, and that
            // dialog only appears while the app is active. Waiting up to a
            // polling interval means the request lands after the user has left
            // the Settings window, so it is refused without ever asking.
            NSApplication.shared.activate(ignoringOtherApps: true)
            Task { await refreshIfNeeded() }
        } else {
            status = nil
            remedy = nil
            lastUsage = nil
            Task { await ingest(nil) }
        }
    }

    /// Polls Anthropic's account usage at most every two hours (sooner after a
    /// failure), only when opted in. Success injects the authoritative windows —
    /// with reset timestamps — into the Claude connector.
    func refreshIfNeeded() async {
        guard isEnabled, Date() >= nextFetchAt else { return }
        switch await fetcher.fetch() {
        case let .usage(usage):
            remedy = nil
            signInGraceUntil = .distantPast
            lastUsage = usage
            await ingest(applyingPreferences(to: usage))
            status = "Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))"
            nextFetchAt = nextFetchAfter(usage)
        case .signedOut:
            await withdrawUsage(remedy: .signIn)
            status = "Not signed in — run `claude auth login` in a terminal"
            nextFetchAt = backoff(normally: 30 * 60)
        case .tokenExpired:
            await withdrawUsage(remedy: .refreshToken)
            status = "Claude sign-in expired — run Claude Code once to refresh it"
            nextFetchAt = backoff(normally: 10 * 60)
        case .keychainAccessDenied:
            await withdrawUsage(remedy: .allowKeychainAccess)
            status = "Keychain access refused — allow the Claude Code credentials item"
            nextFetchAt = backoff(normally: 10 * 60)
        case let .failed(message):
            // Transient: the credentials are fine, so the last usage stays on
            // screen until it ages out of the connector's freshness window.
            remedy = nil
            status = "Couldn't fetch usage: \(message)"
            nextFetchAt = backoff(normally: 10 * 60)
        }
    }

    /// Takes the last fetched usage back off screen. A credential fault cannot
    /// repair itself, so those numbers will never be refreshed again; leaving
    /// them up shows a frozen per-model bar beside live percentages with
    /// nothing to say it stopped moving.
    private func withdrawUsage(remedy newRemedy: AccountUsageRemedy) async {
        remedy = newRemedy
        guard lastUsage != nil else { return }
        lastUsage = nil
        await ingest(nil)
    }

    private func backoff(normally interval: TimeInterval) -> Date {
        let now = Date()
        return now.addingTimeInterval(now < signInGraceUntil ? 30 : interval)
    }

    /// Re-fetch shortly after the soonest window resets (the 5h can lapse
    /// between two-hour polls), but never sooner than 5 min nor later than 2 h.
    /// A window that already lapsed, or that Anthropic reports without a reset
    /// (a 5h window with no usage yet reports `resets_at: null`), is re-polled
    /// at the 5 min floor so the reset shows up as soon as the window is in use
    /// instead of up to two hours later.
    private func nextFetchAfter(_ usage: AccountUsage) -> Date {
        let now = Date()
        let windows = [usage.fiveHour, usage.sevenDay].compactMap { $0 }
        let soonestReset = windows.compactMap(\.resetsAt).filter { $0 > now }.min()
        let hasLapsedOrUnknownReset = windows.contains { window in
            window.resetsAt.map { $0 <= now } ?? true
        }
        let twoHours = now.addingTimeInterval(2 * 60 * 60)
        let candidate = hasLapsedOrUnknownReset
            ? now
            : soonestReset.map { $0.addingTimeInterval(60) } ?? twoHours
        return max(now.addingTimeInterval(5 * 60), min(twoHours, candidate))
    }
}
