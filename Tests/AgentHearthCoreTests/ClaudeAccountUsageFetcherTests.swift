import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

/// Serves canned responses and records the outgoing request so tests can assert
/// the token header and target URL without hitting the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var error: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Stands in for the Keychain so the credential classification can be driven
/// from fixed stores, in the order a real sweep would see them.
private final class StubCredentialStore: ClaudeCredentialStoreReading, @unchecked Sendable {
    /// Service name to what opening it yields, newest store first.
    var items: [(service: String, read: ClaudeCredentialStoreRead)] = []
    var fallback: Data?
    /// Bumped by a test to simulate Claude Code writing a new token.
    var generation = 0
    /// How many times a store was actually opened — the reads that cost the
    /// user a consent dialog.
    private(set) var openCount = 0

    init(items: [(service: String, read: ClaudeCredentialStoreRead)] = [], fallback: Data? = nil) {
        self.items = items
        self.fallback = fallback
    }

    func services() -> [String] { items.map(\.service) }

    func read(service: String) -> ClaudeCredentialStoreRead {
        openCount += 1
        return items.first { $0.service == service }?.read ?? .missing
    }

    func fallbackStore() -> Data? { fallback }

    func stateToken() -> String { "gen-\(generation)" }
}

final class ClaudeAccountUsageFetcherTests: XCTestCase {
    private func makeFetcher() -> ClaudeAccountUsageFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeAccountUsageFetcher(
            now: { Date(timeIntervalSince1970: 1_000) },
            session: URLSession(configuration: config)
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data()
        StubURLProtocol.error = nil
        StubURLProtocol.lastRequest = nil
    }

    func testSuccessDecodesUsageAndSendsBearerTokenToAnthropic() async {
        StubURLProtocol.body = Data(#"{"five_hour":{"utilization":26,"resets_at":"2026-08-24T18:00:00Z"}}"#.utf8)
        let outcome = await makeFetcher().fetchUsage(accessToken: "secret-token")

        guard case let .usage(usage) = outcome else { return XCTFail("expected usage, got \(outcome)") }
        XCTAssertEqual(usage.fiveHour?.utilizationFraction ?? 0, 0.26, accuracy: 0.0001)

        let request = StubURLProtocol.lastRequest
        XCTAssertEqual(request?.url?.host, "api.anthropic.com")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testUnauthorizedMapsToTokenExpired() async {
        StubURLProtocol.status = 401
        let outcome = await makeFetcher().fetchUsage(accessToken: "t")
        guard case .tokenExpired = outcome else { return XCTFail("expected tokenExpired, got \(outcome)") }
    }

    func testServerErrorMapsToFailed() async {
        StubURLProtocol.status = 500
        let outcome = await makeFetcher().fetchUsage(accessToken: "t")
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
    }

    func testUnrecognizedBodyMapsToFailed() async {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("not json".utf8)
        let outcome = await makeFetcher().fetchUsage(accessToken: "t")
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
    }

    func testTransportErrorMapsToFailed() async {
        StubURLProtocol.error = URLError(.timedOut)
        let outcome = await makeFetcher().fetchUsage(accessToken: "t")
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
    }
    // MARK: - Credential store selection

    /// Claude Code 2.1 keeps its sign-in in suffixed items and blanks the bare
    /// one; a store with empty token strings must never count as a sign-in.
    func testBlankedStoreIsNotACredential() {
        let blank = Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#.utf8)
        XCTAssertNil(ClaudeAccountUsageFetcher.parseCredentials(blank))
        XCTAssertNil(ClaudeAccountUsageFetcher.parseCredentials(Data(#"{"mcpOAuth":{}}"#.utf8)))
        XCTAssertNil(ClaudeAccountUsageFetcher.parseCredentials(Data("not json".utf8)))
    }

    func testParsesTokenAndMillisecondExpiry() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1700000000000}}"#.utf8)
        let credentials = try XCTUnwrap(ClaudeAccountUsageFetcher.parseCredentials(data))
        XCTAssertEqual(credentials.accessToken, "tok")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Telling a signed-out account from a refreshable one

    /// The discriminator behind the three credential outcomes: only a refresh
    /// token that is present and unexpired means the CLI can recover on its own.
    func testLiveRefreshTokenIsWhatSeparatesRefreshableFromSignedOut() {
        let now = Date(timeIntervalSince1970: 10_000)
        func store(refreshToken: String, refreshExpiresAt: Int?) -> Data {
            let expiry = refreshExpiresAt.map { ",\"refreshTokenExpiresAt\":\($0)" } ?? ""
            return Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"\#(refreshToken)"\#(expiry)}}"#.utf8)
        }

        XCTAssertTrue(
            ClaudeAccountUsageFetcher.hasLiveRefreshToken(store(refreshToken: "r", refreshExpiresAt: 20_000_000), now: now),
            "a refresh token expiring in the future can still mint an access token"
        )
        XCTAssertFalse(
            ClaudeAccountUsageFetcher.hasLiveRefreshToken(store(refreshToken: "r", refreshExpiresAt: 5_000_000), now: now),
            "a lapsed refresh token cannot"
        )
        XCTAssertFalse(
            ClaudeAccountUsageFetcher.hasLiveRefreshToken(store(refreshToken: "", refreshExpiresAt: 20_000_000), now: now),
            "the logged-out husk Claude Code leaves behind blanks both tokens"
        )
        XCTAssertFalse(
            ClaudeAccountUsageFetcher.hasLiveRefreshToken(store(refreshToken: "r", refreshExpiresAt: nil), now: now),
            "an unverifiable refresh token counts as unusable: pointing the user at a sign-in always works"
        )
        XCTAssertFalse(ClaudeAccountUsageFetcher.hasLiveRefreshToken(Data("not json".utf8), now: now))
    }

    // MARK: - Classification, end to end

    private func makeFetcher(stores: StubCredentialStore) -> ClaudeAccountUsageFetcher {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeAccountUsageFetcher(
            now: { Date(timeIntervalSince1970: 10_000) },
            session: URLSession(configuration: config),
            stores: stores
        )
    }

    /// A husk in front of stores whose refresh tokens have also lapsed. This is
    /// the shape that stranded a real account, and the one that used to be
    /// reported as a mere expiry — sending the user to a button that could not
    /// possibly help.
    func testHuskOverLapsedStoresReportsSignedOut() async {
        let outcome = await makeFetcher(stores: StubCredentialStore(items: [
            ("Claude Code-credentials", .data(Self.husk)),
            ("Claude Code-credentials-00000000000002", .data(Self.lapsedBeyondRefresh)),
        ])).fetch()

        guard case .signedOut = outcome else { return XCTFail("expected signedOut, got \(outcome)") }
    }

    /// The same lapsed access token, but with a refresh token still alive: the
    /// CLI can recover on its own, so this must not ask for a new sign-in.
    func testLapsedTokenWithLiveRefreshReportsExpired() async {
        let outcome = await makeFetcher(stores: StubCredentialStore(items: [
            ("Claude Code-credentials", .data(Self.lapsedButRefreshable)),
        ])).fetch()

        guard case .tokenExpired = outcome else { return XCTFail("expected tokenExpired, got \(outcome)") }
    }

    /// A refused read must not be reported as an absent sign-in: the account is
    /// very possibly fine and only the Keychain dialog needs answering.
    func testRefusedKeychainReadIsNotMistakenForBeingSignedOut() async {
        let outcome = await makeFetcher(stores: StubCredentialStore(items: [
            ("Claude Code-credentials", .denied),
        ])).fetch()

        guard case .keychainAccessDenied = outcome else {
            return XCTFail("expected keychainAccessDenied, got \(outcome)")
        }
    }

    /// The happy path, with the husk in front: a blanked store must be stepped
    /// over rather than shadowing the live token in an older item.
    func testLiveTokenBehindAHuskStillFetchesUsage() async {
        StubURLProtocol.body = Data(#"{"five_hour":{"utilization":26,"resets_at":"2026-08-24T18:00:00Z"}}"#.utf8)
        let outcome = await makeFetcher(stores: StubCredentialStore(items: [
            ("Claude Code-credentials", .data(Self.husk)),
            ("Claude Code-credentials-00000000000002", .data(Self.live)),
        ])).fetch()

        guard case let .usage(usage) = outcome else { return XCTFail("expected usage, got \(outcome)") }
        XCTAssertEqual(usage.fiveHour?.utilizationFraction ?? 0, 0.26, accuracy: 0.0001)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer live-token")
    }

    /// Nothing stored at all is the same problem as a husk: sign in.
    func testNoStoresAtAllReportsSignedOut() async {
        let outcome = await makeFetcher(stores: StubCredentialStore()).fetch()
        guard case .signedOut = outcome else { return XCTFail("expected signedOut, got \(outcome)") }
    }

    /// A fruitless sweep opens every credential item, and each of those reads
    /// can raise a consent dialog. Repeating it on the next poll asked the user
    /// for a password again to reach the identical conclusion, several times an
    /// hour. The verdict is now held until the stores themselves differ.
    func testAFruitlessSweepIsNotRepeatedWhileTheStoresAreUnchanged() async {
        let store = StubCredentialStore(items: [
            ("Claude Code-credentials", .data(Self.husk)),
            ("Claude Code-credentials-00000000000002", .data(Self.lapsedBeyondRefresh)),
        ])
        let fetcher = makeFetcher(stores: store)

        guard case .signedOut = await fetcher.fetch() else { return XCTFail("expected signedOut") }
        let afterFirst = store.openCount
        XCTAssertEqual(afterFirst, 2, "the first sweep opens every store")

        guard case .signedOut = await fetcher.fetch() else { return XCTFail("expected signedOut") }
        guard case .signedOut = await fetcher.fetch() else { return XCTFail("expected signedOut") }
        XCTAssertEqual(store.openCount, afterFirst, "later polls reach the same verdict without opening anything")

        // Claude Code writes a new token: the verdict no longer holds.
        store.generation += 1
        _ = await fetcher.fetch()
        XCTAssertGreaterThan(store.openCount, afterFirst, "a changed store is swept again")
    }

    /// Retry is the one path that should pay for the reads again: someone
    /// pressing it has usually just changed their mind about a dialog, which
    /// no fingerprint of the stores can detect.
    func testAnExplicitRetryReopensTheStores() async {
        let store = StubCredentialStore(items: [("Claude Code-credentials", .denied)])
        let fetcher = makeFetcher(stores: store)

        guard case .keychainAccessDenied = await fetcher.fetch() else { return XCTFail("expected denied") }
        let afterFirst = store.openCount
        _ = await fetcher.fetch()
        XCTAssertEqual(store.openCount, afterFirst, "a plain poll stays quiet")

        await fetcher.forgetRememberedFailure()
        _ = await fetcher.fetch()
        XCTAssertGreaterThan(store.openCount, afterFirst, "an explicit retry asks again")
    }

    // Fixtures, in the shapes Claude Code actually writes. Clock is 10_000s.
    private static let husk = Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"refreshTokenExpiresAt":20000000}}"#.utf8)
    private static let lapsedBeyondRefresh = Data(#"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"r","expiresAt":5000000,"refreshTokenExpiresAt":5000000}}"#.utf8)
    private static let lapsedButRefreshable = Data(#"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"r","expiresAt":5000000,"refreshTokenExpiresAt":90000000}}"#.utf8)
    private static let live = Data(#"{"claudeAiOauth":{"accessToken":"live-token","refreshToken":"r","expiresAt":90000000,"refreshTokenExpiresAt":90000000}}"#.utf8)

    /// The exact shape that stranded a real account: the newest store is a
    /// logged-out husk and every older store has lapsed past refresh, so the
    /// only way back is a sign-in — not the "open Claude Code" advice.
    func testSignedOutHuskBesideLapsedStoresOffersNoRefreshPath() {
        let now = Date(timeIntervalSince1970: 10_000)
        let husk = Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"refreshTokenExpiresAt":20000000}}"#.utf8)
        let lapsed = Data(#"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":5000000,"refreshTokenExpiresAt":5000000}}"#.utf8)

        XCTAssertNil(ClaudeAccountUsageFetcher.parseCredentials(husk))
        XCTAssertFalse([husk, lapsed].contains { ClaudeAccountUsageFetcher.hasLiveRefreshToken($0, now: now) })
    }
}
