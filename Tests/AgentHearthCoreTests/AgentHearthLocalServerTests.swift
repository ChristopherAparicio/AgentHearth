import Darwin
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

    /// Regression: a negative `Content-Length` built an inverted `Range` in the
    /// request reader and trapped the whole process — before the Origin/token
    /// checks, so any local process could crash the app with one request.
    func testRejectsNegativeContentLengthWithoutCrashing() async throws {
        let box = Box()
        _ = try makeServer(box)
        // Warm up: URLSession's retry loop also waits for the accept loop.
        _ = try await getHealth()

        let malicious = "POST /v1/providers/claude-code/events HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        let response = try sendRaw(malicious)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), "got: \(response)")

        let oversized = "POST /v1/providers/claude-code/events HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\nContent-Length: 99999999999\r\n\r\n"
        XCTAssertTrue(try sendRaw(oversized).hasPrefix("HTTP/1.1 400"))

        // The server is still alive and functional afterwards.
        let (status, _) = try await getHealth()
        XCTAssertEqual(status, 200)
        let count = await box.count
        XCTAssertEqual(count, 0)
    }

    /// Writes raw bytes to the server socket (URLSession cannot emit an invalid
    /// Content-Length) and returns the response head.
    private func sendRaw(_ request: String) throws -> String {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(socket, 0)
        defer { Darwin.close(socket) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect failed: errno \(errno)")
        let bytes = Array(request.utf8)
        XCTAssertEqual(Darwin.send(socket, bytes, bytes.count, 0), bytes.count)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let received = Darwin.recv(socket, &buffer, buffer.count, 0)
        guard received > 0 else { return "<no response, errno \(errno)>" }
        return String(decoding: buffer[..<received], as: UTF8.self)
    }

    private func getHealth() async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }
}
