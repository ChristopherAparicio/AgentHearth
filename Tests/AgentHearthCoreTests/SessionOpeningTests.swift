import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class SessionOpeningTests: XCTestCase {
    func testAllProvidersDefaultToExactTerminalResume() {
        let preferences = SessionOpenPreferences()

        XCTAssertEqual(preferences.destination(for: .codex), .terminal)
        XCTAssertEqual(preferences.destination(for: .claudeCode), .terminal)
        XCTAssertEqual(preferences.destination(for: .openCode), .terminal)
    }

    func testRemoteSessionsAlwaysResolveToTerminal() {
        var preferences = SessionOpenPreferences(codex: .providerApp, claudeCode: .providerApp, openCode: .providerApp)
        preferences.setDestination(.providerApp, for: .codex)
        let target = SessionTarget(
            providerID: .codex,
            sessionID: "thread-123",
            host: AgentHost(id: "remote", displayName: "Build Mac", kind: .ssh, sshDestination: "build")
        )

        XCTAssertEqual(preferences.effectiveDestination(for: target), .terminal)
    }

    func testCodexAppRouteDoesNotPretendToResumeTheCLIThread() throws {
        let target = SessionTarget(providerID: .codex, sessionID: "thread-123")

        XCTAssertNil(try ProviderAppSessionURL.url(for: target))
    }

    func testClaudeCodeAppRouteResumesTheExactSession() throws {
        let sessionID = "e3f43e4d-dd43-4d93-9bb6-ae389b81b431"
        let target = SessionTarget(providerID: .claudeCode, sessionID: sessionID)

        let route = try ProviderAppSessionURL.url(for: target)
        XCTAssertEqual(route?.scheme, ProviderDesktopApp.ClaudeDesktopRoute.scheme)
        XCTAssertEqual(route?.host, ProviderDesktopApp.ClaudeDesktopRoute.resumeHost)
        let queryItems = URLComponents(url: route!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(
            queryItems,
            [URLQueryItem(name: ProviderDesktopApp.ClaudeDesktopRoute.sessionQueryItem, value: sessionID)]
        )
    }

    func testClaudeCodeAppRouteRejectsNonUUIDSessionIDs() throws {
        let target = SessionTarget(providerID: .claudeCode, sessionID: "not-a-session-uuid")

        XCTAssertNil(try ProviderAppSessionURL.url(for: target))
    }

    func testClaudeDesktopLocalSessionRouteOpensTheExactCodeSession() throws {
        let target = SessionTarget(
            providerID: .claudeCode,
            sessionID: "local_10523c37-0c9b-4e3d-bd1b-cc1ec1532eb5"
        )

        let route = try XCTUnwrap(ProviderAppSessionURL.url(for: target))
        XCTAssertEqual(route.absoluteString, "claude://claude.ai/epitaxy/local_10523c37-0c9b-4e3d-bd1b-cc1ec1532eb5")
    }

    func testClaudeDesktopLocalSessionRouteRejectsMalformedIDs() throws {
        let target = SessionTarget(providerID: .claudeCode, sessionID: "local_not-a-uuid")

        XCTAssertNil(try ProviderAppSessionURL.url(for: target))
    }

    func testClaudeDesktopMappingNavigatesWithoutResumingTheCLISession() throws {
        let cliSessionID = "e28da872-881a-4282-a0cc-ad72918fa40d"
        let localSessionID = "local_10523c37-0c9b-4e3d-bd1b-cc1ec1532eb5"
        let target = SessionTarget(providerID: .claudeCode, sessionID: cliSessionID)

        let route = try XCTUnwrap(
            ProviderAppSessionURL.url(for: target, claudeDesktopSessionID: localSessionID)
        )

        XCTAssertEqual(route.absoluteString, "claude://claude.ai/epitaxy/\(localSessionID)")
        XCTAssertNotEqual(route.host, ProviderDesktopApp.ClaudeDesktopRoute.resumeHost)
    }

    func testClaudeDesktopResolverMapsCLIToExistingLocalSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-ClaudeDesktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let accountDirectory = root.appending(path: "organization/account")
        try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        let localSessionID = "local_10523c37-0c9b-4e3d-bd1b-cc1ec1532eb5"
        let cliSessionID = "e28da872-881a-4282-a0cc-ad72918fa40d"
        let sessionFile = accountDirectory.appending(path: "\(localSessionID).json")
        try Data(#"{"sessionId":"local_10523c37-0c9b-4e3d-bd1b-cc1ec1532eb5","cliSessionId":"e28da872-881a-4282-a0cc-ad72918fa40d","title":"Ignored"}"#.utf8)
            .write(to: sessionFile)

        let resolver = ClaudeDesktopSessionResolver(sessionsURL: root)

        XCTAssertEqual(resolver.localSessionID(for: cliSessionID), localSessionID)
        XCTAssertNil(resolver.localSessionID(for: "00000000-0000-0000-0000-000000000000"))
    }

    func testClaudeCodeAppRouteIsLocalOnly() throws {
        let target = SessionTarget(
            providerID: .claudeCode,
            sessionID: "e3f43e4d-dd43-4d93-9bb6-ae389b81b431",
            host: AgentHost(id: "remote", displayName: "Build Mac", kind: .ssh, sshDestination: "build")
        )

        XCTAssertNil(try ProviderAppSessionURL.url(for: target))
    }

    func testOpenCodeNativeRouteUsesItsProjectDirectory() throws {
        let target = SessionTarget(
            providerID: .openCode,
            sessionID: "session-123",
            workingDirectory: URL(fileURLWithPath: "/Users/me/My Project")
        )

        let route = try ProviderAppSessionURL.url(for: target)
        XCTAssertEqual(route?.scheme, "opencode")
        XCTAssertEqual(route?.host, "open-project")
        XCTAssertEqual(URLComponents(url: route!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "/Users/me/My Project")
    }
}
