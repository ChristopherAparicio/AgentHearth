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

    func testSelectsTheFreshestValidTokenAcrossStores() {
        let now = Date(timeIntervalSince1970: 10_000)
        let stale = ClaudeAccountUsageFetcher.Credentials(accessToken: "old", expiresAt: now.addingTimeInterval(-3_600))
        let soon = ClaudeAccountUsageFetcher.Credentials(accessToken: "soon", expiresAt: now.addingTimeInterval(600))
        let later = ClaudeAccountUsageFetcher.Credentials(accessToken: "later", expiresAt: now.addingTimeInterval(7_200))
        XCTAssertEqual(ClaudeAccountUsageFetcher.selectFreshest([stale, soon, later], now: now)?.accessToken, "later")
        XCTAssertEqual(ClaudeAccountUsageFetcher.selectFreshest([stale], now: now)?.accessToken, "old", "an expired token still reports as expired rather than missing")
        XCTAssertNil(ClaudeAccountUsageFetcher.selectFreshest([], now: now))
    }
}
