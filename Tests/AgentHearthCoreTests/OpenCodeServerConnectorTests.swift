import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class OpenCodeServerConnectorTests: XCTestCase {
    func testNormalizesAConfiguredServerAndPreservesItsSource() async throws {
        let loader = StubOpenCodeServerLoader(responses: [
            "/session": Data("""
            [{
              "id":"session-1",
              "title":"Multi-server work",
              "directory":"/tmp/AgentHearth",
              "time":{"updated":1999500},
              "model":{"id":"gpt-5.6-sol","providerID":"openai"}
            }]
            """.utf8),
            "/session/status": Data("""
            {"session-1":{"type":"busy"}}
            """.utf8),
            "/session/session-1/message": Data("""
            [
              {"info":{"role":"assistant","providerID":"openai","modelID":"gpt-5.6-sol","time":{"created":1900000,"completed":1901000},"tokens":{"cache":{"read":0,"write":1000}},"finish":"stop"}},
              {"info":{"role":"assistant","providerID":"openai","modelID":"gpt-5.6-sol","time":{"created":1950000,"completed":1951000},"tokens":{"cache":{"read":8000,"write":0}},"finish":"stop"}}
            ]
            """.utf8),
        ])
        let server = OpenCodeServerConfiguration(
            id: "main-server",
            displayName: "Desktop OpenCode",
            port: 4097
        )
        let connector = OpenCodeServerConnector(
            configuration: server,
            loader: loader,
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let snapshot = try await connector.snapshot()

        XCTAssertEqual(snapshot.connectionState, .connected)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].status, .working)
        XCTAssertEqual(snapshot.sessions[0].source, server.source)
        XCTAssertEqual(snapshot.sessions[0].target?.sessionID, "session-1")
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.hitCount, 1)
        XCTAssertEqual(snapshot.sessions[0].cacheHealth?.expectedColdStartCount, 1)
    }

    func testMessageMetadataIsCachedUntilSessionChanges() async throws {
        let loader = StubOpenCodeServerLoader(responses: [
            "/session": Data("""
            [{"id":"session-1","title":"Cached","directory":"/tmp/project","time":{"updated":1999500}}]
            """.utf8),
            "/session/status": Data("{}".utf8),
            "/session/session-1/message": Data("[]".utf8),
        ])
        let connector = OpenCodeServerConnector(
            configuration: OpenCodeServerConfiguration(displayName: "Server"),
            loader: loader,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        await connector.setSourceMode(.localOnly)

        _ = try await connector.snapshot()
        _ = try await connector.snapshot()

        let messageRequestCount = await loader.count(for: "/session/session-1/message")
        XCTAssertEqual(messageRequestCount, 1)
    }
}

private actor StubOpenCodeServerLoader: OpenCodeServerLoading {
    private let responses: [String: Data]
    private var requestCounts: [String: Int] = [:]

    init(responses: [String: Data]) {
        self.responses = responses
    }

    func load(path: String, port: Int) async throws -> Data {
        requestCounts[path, default: 0] += 1
        guard let response = responses[path] else { throw OpenCodeServerError.invalidResponse }
        return response
    }

    func count(for path: String) -> Int {
        requestCounts[path, default: 0]
    }
}
