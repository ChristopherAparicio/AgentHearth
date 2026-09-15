import AgentHearthCore
import Foundation
import XCTest

/// Returns whatever it is told to, and counts what it was asked.
private final class FakeAccountUsageFetcher: AccountUsageFetching, @unchecked Sendable {
    var outcome: AccountUsageFetchOutcome = .signedOut
    private(set) var fetchCount = 0
    private(set) var forgetCount = 0
    /// Held while a fetch is in flight so a second, concurrent call is
    /// observable rather than merely fast.
    var gate: (@Sendable () async -> Void)?

    func fetch() async -> AccountUsageFetchOutcome {
        fetchCount += 1
        await gate?()
        return outcome
    }

    func forgetRememberedFailure() async {
        forgetCount += 1
    }
}

@MainActor
final class AccountUsagePollerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "AccountUsagePollerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makePoller(
        _ fetcher: FakeAccountUsageFetcher
    ) -> (AccountUsagePoller, () -> [AccountUsage?]) {
        let preferences = PreferencesStore(defaults: defaults)
        preferences.claudeAccountUsageEnabled = true
        let poller = AccountUsagePoller(fetcher: fetcher, preferences: preferences)
        let ingested = Ingested()
        poller.ingest = { @MainActor usage in ingested.values.append(usage) }
        return (poller, { ingested.values })
    }

    @MainActor
    private final class Ingested {
        var values: [AccountUsage?] = []
    }

    private func usage(
        fiveHour: Double = 0.4,
        resetsAt: Date? = Date().addingTimeInterval(3 * 60 * 60),
        scopedWeekly: [AccountUsage.ScopedWindow] = []
    ) -> AccountUsage {
        AccountUsage(
            fiveHour: AccountUsage.Window(utilizationFraction: fiveHour, resetsAt: resetsAt),
            sevenDay: AccountUsage.Window(
                utilizationFraction: 0.2,
                resetsAt: Date().addingTimeInterval(5 * 24 * 60 * 60)
            ),
            scopedWeekly: scopedWeekly,
            fetchedAt: Date()
        )
    }

    // MARK: - What the user is told to do

    func testSignedOutAsksForASignInRatherThanARefresh() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .signedOut

        await poller.refreshIfNeeded()

        XCTAssertEqual(poller.remedy, .signIn)
        XCTAssertEqual(poller.status, "Not signed in — run `claude auth login` in a terminal")
    }

    func testEachCredentialFaultCarriesItsOwnRemedy() async {
        let cases: [(AccountUsageFetchOutcome, AccountUsageRemedy)] = [
            (.signedOut, .signIn),
            (.tokenExpired, .refreshToken),
            (.keychainAccessDenied, .allowKeychainAccess),
        ]
        for (outcome, expected) in cases {
            let fetcher = FakeAccountUsageFetcher()
            let (poller, _) = makePoller(fetcher)
            fetcher.outcome = outcome
            await poller.refreshIfNeeded()
            XCTAssertEqual(poller.remedy, expected)
        }
    }

    func testATransientFailureNamesNoRemedy() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, ingested) = makePoller(fetcher)
        fetcher.outcome = .usage(usage())
        await poller.refreshIfNeeded()

        fetcher.outcome = .failed("network down")
        await poller.retryNow()
        await poller.refreshIfNeeded()

        XCTAssertNil(poller.remedy)
        // The numbers stay on screen: they will be refreshed once the network is back.
        XCTAssertEqual(ingested().count, 1)
    }

    // MARK: - Withdrawing figures that can no longer be refreshed

    func testACredentialFaultTakesTheLastFiguresBackOffScreen() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, ingested) = makePoller(fetcher)
        fetcher.outcome = .usage(usage())
        await poller.refreshIfNeeded()
        XCTAssertEqual(ingested().count, 1)

        fetcher.outcome = .signedOut
        await poller.retryNow()
        await poller.refreshIfNeeded()

        XCTAssertEqual(ingested().count, 2)
        XCTAssertNil(ingested().last!, "stale percentages must not outlive the sign-in that fed them")
    }

    func testNothingIsWithdrawnWhenNothingWasEverShown() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, ingested) = makePoller(fetcher)
        fetcher.outcome = .keychainAccessDenied

        await poller.refreshIfNeeded()

        XCTAssertTrue(ingested().isEmpty)
    }

    // MARK: - Sweeping the Keychain once

    func testTwoConcurrentRefreshesSweepTheKeychainOnce() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .usage(usage())
        let released = expectation(description: "first fetch released")
        fetcher.gate = { @Sendable in
            try? await Task.sleep(for: .milliseconds(50))
        }

        async let first: Void = poller.refreshIfNeeded()
        async let second: Void = poller.refreshIfNeeded()
        _ = await (first, second)
        released.fulfill()
        await fulfillment(of: [released], timeout: 1)

        XCTAssertEqual(fetcher.fetchCount, 1, "a second sweep would show the consent dialogs twice")
    }

    // MARK: - The backoff schedule

    func testASuccessfulFetchIsRepolledJustAfterTheSoonestReset() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        let reset = Date().addingTimeInterval(45 * 60)
        fetcher.outcome = .usage(usage(resetsAt: reset))

        await poller.refreshIfNeeded()

        XCTAssertEqual(poller.nextFetchAt.timeIntervalSince(reset), 60, accuracy: 2)
    }

    func testAResetTooCloseIsFlooredAtFiveMinutes() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .usage(usage(resetsAt: Date().addingTimeInterval(30)))

        await poller.refreshIfNeeded()

        XCTAssertEqual(poller.nextFetchAt.timeIntervalSinceNow, 5 * 60, accuracy: 2)
    }

    func testADistantResetIsCappedAtTwoHours() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .usage(usage(resetsAt: Date().addingTimeInterval(4 * 24 * 60 * 60)))

        await poller.refreshIfNeeded()

        XCTAssertEqual(poller.nextFetchAt.timeIntervalSinceNow, 2 * 60 * 60, accuracy: 2)
    }

    func testAWindowWithNoResetYetIsRepolledAtTheFloor() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        // Anthropic reports `resets_at: null` for a 5h window with no usage yet.
        fetcher.outcome = .usage(usage(resetsAt: nil))

        await poller.refreshIfNeeded()

        XCTAssertEqual(poller.nextFetchAt.timeIntervalSinceNow, 5 * 60, accuracy: 2)
    }

    func testAFreshSignInShortensTheFailureBackoffToSeconds() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .signedOut

        poller.expectSignInRefresh()
        await poller.retryNow()
        await poller.refreshIfNeeded()

        XCTAssertEqual(
            poller.nextFetchAt.timeIntervalSinceNow,
            30,
            accuracy: 2,
            "a half-hour backoff strands someone who finished logging in two minutes ago"
        )
    }

    func testTheGraceEndsOnceUsageFlowsAgain() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        poller.expectSignInRefresh()

        fetcher.outcome = .usage(usage())
        await poller.retryNow()
        await poller.refreshIfNeeded()

        fetcher.outcome = .signedOut
        await poller.retryNow()
        await poller.refreshIfNeeded()

        XCTAssertEqual(poller.nextFetchAt.timeIntervalSinceNow, 30 * 60, accuracy: 2)
    }

    func testTheScheduleHoldsUntilItIsDue() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .usage(usage())

        await poller.refreshIfNeeded()
        await poller.refreshIfNeeded()

        XCTAssertEqual(fetcher.fetchCount, 1)
    }

    // MARK: - Retry

    func testRetryForgetsTheRememberedVerdictAsWellAsTheBackoff() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        fetcher.outcome = .keychainAccessDenied
        await poller.refreshIfNeeded()

        await poller.retryNow()
        await poller.refreshIfNeeded()

        XCTAssertEqual(fetcher.forgetCount, 1, "Retry is the one path that should pay for the reads again")
        XCTAssertEqual(fetcher.fetchCount, 2)
    }

    func testRetryDoesNothingWhileTheFeatureIsOff() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, _) = makePoller(fetcher)
        poller.isEnabled = false

        await poller.retryNow()
        await poller.refreshIfNeeded()

        XCTAssertEqual(fetcher.fetchCount, 0)
        XCTAssertEqual(fetcher.forgetCount, 0)
    }

    // MARK: - The scoped-weekly preference

    func testHidingPerModelLimitsReappliesWithoutAnotherFetch() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, ingested) = makePoller(fetcher)
        let scoped = AccountUsage.ScopedWindow(
            id: "fable",
            label: "Fable",
            window: AccountUsage.Window(utilizationFraction: 0.9, resetsAt: nil),
            isActive: true
        )
        fetcher.outcome = .usage(usage(scopedWeekly: [scoped]))
        await poller.refreshIfNeeded()
        XCTAssertEqual(poller.scopedWeeklyLimitLabels, ["Fable"])

        poller.showsScopedWeeklyLimits = false
        await Task.yield()

        XCTAssertEqual(fetcher.fetchCount, 1)
        XCTAssertEqual(ingested().count, 2)
        XCTAssertEqual(ingested().last??.scopedWeekly, [])
    }

    func testSwitchingTheFeatureOffClearsEverythingItPutOnScreen() async {
        let fetcher = FakeAccountUsageFetcher()
        let (poller, ingested) = makePoller(fetcher)
        fetcher.outcome = .signedOut
        await poller.refreshIfNeeded()
        XCTAssertNotNil(poller.remedy)

        poller.setEnabled(false)
        await Task.yield()

        XCTAssertNil(poller.remedy)
        XCTAssertNil(poller.status)
        XCTAssertEqual(ingested().last ?? nil, nil)
    }
}
