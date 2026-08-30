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
    private var nextFetchAt: Date = .distantPast

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
        switch await fetcher.fetch() {
        case let .usage(usage):
            await ingest(usage)
            status = "Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))"
            // Re-fetch shortly after the soonest window resets (the 5h can lapse
            // between two-hour polls), but never sooner than 5 min nor later
            // than 2 h.
            let now = Date()
            let soonestReset = [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt]
                .compactMap { $0 }
                .filter { $0 > now }
                .min()
            let twoHours = now.addingTimeInterval(2 * 60 * 60)
            let candidate = soonestReset.map { $0.addingTimeInterval(60) } ?? twoHours
            nextFetchAt = max(now.addingTimeInterval(5 * 60), min(twoHours, candidate))
        case .tokenExpired:
            status = "Token expired — use Claude Desktop to refresh it, then retry"
            nextFetchAt = Date().addingTimeInterval(10 * 60)
        case .tokenMissing:
            status = "No Claude credentials found in the Keychain"
            nextFetchAt = Date().addingTimeInterval(30 * 60)
        case let .failed(message):
            status = "Couldn't fetch usage: \(message)"
            nextFetchAt = Date().addingTimeInterval(10 * 60)
        }
    }
}
