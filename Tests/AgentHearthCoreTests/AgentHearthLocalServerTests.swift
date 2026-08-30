import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

private actor Box {
    private(set) var events: [ClaudeCodeHookEvent] = []
    func append(_ event: ClaudeCodeHookEvent) { events.append(event) }
    var count: Int { events.count }
    var last: ClaudeCodeHookEvent? { events.last }
}

final class AgentHearthLocalServerTests: XCTestCase {
    private var server: AgentHearthLocalServer?
    private let port: UInt16 = 5987

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func makeServer(_ box: Box, token: String? = nil) throws -> AgentHearthLocalServer {
        let server = AgentHearthLocalServer(
            port: port,
            token: token,
            ingestOpenCode: { _ in },
            ingestClaudeCode: { event in await box.append(event) }
        )
        try server.start()
        self.server = server
        return server
    }

    private func post(
        _ path: String,
        body: String,
        headers: [String: String] = [:]
    ) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // The accept loop starts on a background queue; retry briefly on refusal.
        for attempt in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
            } catch {
                if attempt == 19 { throw error }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return (-1, Data())
    }

    func testAcceptsValidClaudeEventAndCountsIt() async throws {
        let box = Box()
        _ = try makeServer(box)
        let body = #"{"schemaVersion":1,"eventName":"Stop","sessionID":"s-1","sentAt":1700000000000}"#
        let (status, _) = try await post("/v1/providers/claude-code/events", body: body)
        XCTAssertEqual(status, 202)
        let count = await box.count
        XCTAssertEqual(count, 1)
        let lastSessionID = await box.last?.sessionID
        XCTAssertEqual(lastSessionID, "s-1")

        let (healthStatus, healthData) = try await getHealth()
        XCTAssertEqual(healthStatus, 200)
        let health = try XCTUnwrap(try JSONSerialization.jsonObject(with: healthData) as? [String: Any])
        XCTAssertEqual(health["ok"] as? Bool, true)
        XCTAssertEqual(health["acceptedClaudeCodeEvents"] as? Int, 1)
    }

    func testRejectsMalformedJSON() async throws {
        _ = try makeServer(Box())
        let (status, _) = try await post("/v1/providers/claude-code/events", body: "{ not json")
        XCTAssertEqual(status, 400)
    }

    func testRejectsUnsupportedSchemaVersion() async throws {
        _ = try makeServer(Box())
        let body = #"{"schemaVersion":99,"eventName":"Stop","sessionID":"s-1","sentAt":1700000000000}"#
        let (status, _) = try await post("/v1/providers/claude-code/events", body: body)
        XCTAssertEqual(status, 409)
    }

    func testRejectsRequestCarryingOriginHeader() async throws {
        let box = Box()
        _ = try makeServer(box)
        let body = #"{"schemaVersion":1,"eventName":"Stop","sessionID":"s-1","sentAt":1700000000000}"#
        let (status, _) = try await post(
            "/v1/providers/claude-code/events",
            body: body,
            headers: ["Origin": "https://evil.example"]
        )
        XCTAssertEqual(status, 403)
        let count = await box.count
        XCTAssertEqual(count, 0)
    }

    func testRejectsMissingTokenWhenTokenRequired() async throws {
        let box = Box()
        _ = try makeServer(box, token: "s3cret-token")
        let body = #"{"schemaVersion":1,"eventName":"Stop","sessionID":"s-1","sentAt":1700000000000}"#
        let (status, _) = try await post("/v1/providers/claude-code/events", body: body)
        XCTAssertEqual(status, 401)
        let count = await box.count
        XCTAssertEqual(count, 0)
    }

    func testAcceptsMatchingTokenWhenTokenRequired() async throws {
        let box = Box()
        _ = try makeServer(box, token: "s3cret-token")
        let body = #"{"schemaVersion":1,"eventName":"Stop","sessionID":"s-1","sentAt":1700000000000}"#
        let (status, _) = try await post(
            "/v1/providers/claude-code/events",
            body: body,
            headers: ["X-AgentHearth-Token": "s3cret-token"]
        )
        XCTAssertEqual(status, 202)
        let count = await box.count
        XCTAssertEqual(count, 1)
    }

    private func getHealth() async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }
}
