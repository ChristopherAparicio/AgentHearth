import AgentHearthCore
import Foundation
import Observation

/// Abstracts the Anthropic account-usage fetch so `AccountUsagePoller` can be
/// exercised with a fake instead of the Keychain-backed fetcher.
protocol AccountUsageFetching: Sendable {
    func fetch() async -> AccountUsageFetchOutcome
}

extension ClaudeAccountUsageFetcher: AccountUsageFetching {}

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
    /// True after the last fetch found no usable token: the user has to run
    /// Claude Code once so it refreshes its sign-in.
    private(set) var needsSignInRefresh = false
    private var nextFetchAt: Date = .distantPast

    /// Forgets the backoff so the next refresh fetches immediately.
    func retryNow() {
        guard isEnabled else { return }
        nextFetchAt = .distantPast
    }

    /// After the user launched Claude Code to refresh its token: give it a
    /// moment to sign in, then fetch again without waiting out the backoff.
    func expectSignInRefresh() {
        guard isEnabled else { return }
        nextFetchAt = Date().addingTimeInterval(20)
        status = "Waiting for Claude Code to refresh its sign-in…"
    }

    init(fetcher: any AccountUsageFetching, preferences: PreferencesStore) {
        self.fetcher = fetcher
        self.preferences = preferences
        self.isEnabled = preferences.claudeAccountUsageEnabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            nextFetchAt = .distantPast // fetch on the next refresh
        } else {
            status = nil
            Task { await ingest(nil) }
        }
    }

    /// Polls Anthropic's account usage at most every two hours (sooner after a
    /// failure), only when opted in. Success injects the authoritative windows —
    /// with reset timestamps — into the Claude connector.
    func refreshIfNeeded() async {
        guard isEnabled, Date() >= nextFetchAt else { return }
        let outcome = await fetcher.fetch()
        switch outcome {
        case .tokenExpired, .tokenMissing: needsSignInRefresh = true
        case .usage, .failed: needsSignInRefresh = false
        }
        switch outcome {
        case let .usage(usage):
            await ingest(usage)
            status = "Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))"
            // Re-fetch shortly after the soonest window resets (the 5h can lapse
            // between two-hour polls), but never sooner than 5 min nor later
            // than 2 h. A window that already lapsed, or that Anthropic reports
            // without a reset (a 5h window with no usage yet reports
            // `resets_at: null`), is re-polled at the 5 min floor so the reset
            // shows up as soon as the window is in use instead of up to two
            // hours later.
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
            nextFetchAt = max(now.addingTimeInterval(5 * 60), min(twoHours, candidate))
        case .tokenExpired:
            status = "Claude sign-in expired — run Claude Code once to refresh it"
            nextFetchAt = Date().addingTimeInterval(10 * 60)
        case .tokenMissing:
            status = "No Claude sign-in found in the Keychain — run Claude Code and sign in"
            nextFetchAt = Date().addingTimeInterval(30 * 60)
        case let .failed(message):
            status = "Couldn't fetch usage: \(message)"
            nextFetchAt = Date().addingTimeInterval(10 * 60)
        }
    }
}
