import AgentHearthApplication
import AgentHearthDomain
import Darwin
import Foundation

public enum AgentHearthLocalServerError: LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(port: UInt16, error: Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .socketCreationFailed(error):
            "Could not create the local connector socket (errno \(error))"
        case let .bindFailed(port, error):
            "Could not listen on 127.0.0.1:\(port) (errno \(error))"
        case let .listenFailed(error):
            "Could not start the local connector listener (errno \(error))"
        }
    }
}

/// A deliberately small loopback-only HTTP ingress for local provider plugins.
/// The server accepts metadata snapshots and never exposes conversation data.
public final class AgentHearthLocalServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 5274

    private let port: UInt16
    private let token: String?
    private let ingestOpenCode: @Sendable (OpenCodePushPayload) async throws -> Void
    private let ingestCodex: @Sendable (CodexHookEvent) async throws -> Void
    private let ingestClaudeCode: @Sendable (ClaudeCodeHookEvent) async throws -> Void
    private let ingestClaudeCodeStatus: @Sendable (ClaudeCodeStatusEvent) async throws -> Void
    private let queue = DispatchQueue(label: "com.guardix.agenthearth.connector-server")
    private let clientQueue = DispatchQueue(
        label: "com.guardix.agenthearth.connector-clients",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var listeningSocket: Int32 = -1
    private var acceptedOpenCodePayloadCount = 0
    private var lastOpenCodePayloadAt: Date?
    private var acceptedClaudeCodeEventCount = 0
    private var lastClaudeCodeEventAt: Date?
    private var acceptedClaudeCodeStatusCount = 0
    private var acceptedCodexEventCount = 0
    private var lastCodexEventAt: Date?

    /// - Parameter token: shared secret every request must present in the
    ///   `X-AgentHearth-Token` header. When `nil`, token authentication is
    ///   disabled (used only in tests); the cross-origin (`Origin` header)
    ///   rejection stays active regardless.
    public init(
        port: UInt16 = AgentHearthLocalServer.defaultPort,
        token: String? = nil,
        ingestOpenCode: @escaping @Sendable (OpenCodePushPayload) async throws -> Void,
        ingestCodex: @escaping @Sendable (CodexHookEvent) async throws -> Void = { _ in },
        ingestClaudeCode: @escaping @Sendable (ClaudeCodeHookEvent) async throws -> Void = { _ in },
        ingestClaudeCodeStatus: @escaping @Sendable (ClaudeCodeStatusEvent) async throws -> Void = { _ in }
    ) {
        self.port = port
        self.token = token
        self.ingestOpenCode = ingestOpenCode
        self.ingestCodex = ingestCodex
        self.ingestClaudeCode = ingestClaudeCode
        self.ingestClaudeCodeStatus = ingestClaudeCodeStatus
    }

    deinit {
        stop()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listeningSocket < 0 else { return }

        let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw AgentHearthLocalServerError.socketCreationFailed(errno)
        }

        var reuseAddress: Int32 = 1
        setsockopt(
            serverSocket,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(serverSocket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(serverSocket)
            throw AgentHearthLocalServerError.bindFailed(port: port, error: code)
        }

        guard Darwin.listen(serverSocket, 16) == 0 else {
            let code = errno
            Darwin.close(serverSocket)
            throw AgentHearthLocalServerError.listenFailed(code)
        }

        listeningSocket = serverSocket
        queue.async { [weak self] in
            self?.acceptConnections(on: serverSocket)
        }
    }

    public func stop() {
        lock.lock()
        let socketToClose = listeningSocket
        listeningSocket = -1
        lock.unlock()

        if socketToClose >= 0 {
            Darwin.shutdown(socketToClose, SHUT_RDWR)
            Darwin.close(socketToClose)
        }
    }

    private func acceptConnections(on serverSocket: Int32) {
        while true {
            lock.lock()
            let isCurrentSocket = listeningSocket == serverSocket
            lock.unlock()
            guard isCurrentSocket else { return }

            var address = sockaddr_in()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.accept(serverSocket, socketAddress, &addressLength)
                }
            }
            guard clientSocket >= 0 else {
                if errno == EINTR { continue }
                return
            }

            // Bound how long a single client can hold a worker: without a
            // receive timeout, a peer that connects and stalls (or under-sends
            // its Content-Length) would pin a concurrent worker forever and,
            // with enough such peers, exhaust the pool.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientSocket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            clientQueue.async { [weak self] in
                self?.handle(clientSocket)
            }
        }
    }

    private func handle(_ clientSocket: Int32) {
        defer { Darwin.close(clientSocket) }

        guard let request = LocalHTTPRequestReader().readRequest(from: clientSocket) else {
            sendJSON(clientSocket, status: 400, body: #"{"error":"invalid request"}"#)
            return
        }

        // Reject anything a browser could originate. Cross-origin (and
        // cross-port same-site) requests always carry an `Origin` header, while
        // the CLI/plugin clients never send one; this closes the DNS-rebinding
        // and CSRF paths that would otherwise let a visited web page POST forged
        // sessions into the menu bar.
        if request.headers["origin"] != nil {
            sendJSON(clientSocket, status: 403, body: #"{"error":"forbidden"}"#)
            return
        }

        // Require the per-install shared secret so an unprivileged local process
        // cannot spoof provider activity either.
        if let token {
            let presented = request.headers[AgentHearthIngressToken.headerName.lowercased()] ?? ""
            guard constantTimeEquals(presented, token) else {
                sendJSON(clientSocket, status: 401, body: #"{"error":"unauthorized"}"#)
                return
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            sendJSON(clientSocket, status: 200, body: healthJSON())

        case ("POST", "/v1/providers/opencode/snapshots"):
            ingest(
                OpenCodePushPayload.self,
                from: request,
                on: clientSocket,
                invalidPayloadBody: #"{"error":"invalid OpenCode payload"}"#,
                recordAccepted: recordAcceptedOpenCodePayload,
                using: ingestOpenCode
            )

        case ("POST", "/v1/providers/codex/events"):
            ingest(
                CodexHookEvent.self,
                from: request,
                on: clientSocket,
                invalidPayloadBody: #"{"error":"invalid Codex event"}"#,
                recordAccepted: recordAcceptedCodexEvent,
                using: ingestCodex
            )

        case ("POST", "/v1/providers/claude-code/events"):
            ingest(
                ClaudeCodeHookEvent.self,
                from: request,
                on: clientSocket,
                invalidPayloadBody: #"{"error":"invalid Claude Code event"}"#,
                recordAccepted: recordAcceptedClaudeCodeEvent,
                using: ingestClaudeCode
            )

        case ("POST", "/v1/providers/claude-code/status"):
            ingest(
                ClaudeCodeStatusEvent.self,
                from: request,
                on: clientSocket,
                invalidPayloadBody: #"{"error":"invalid Claude Code status"}"#,
                recordAccepted: recordAcceptedClaudeCodeStatus,
                using: ingestClaudeCodeStatus
            )

        default:
            sendJSON(clientSocket, status: 404, body: #"{"error":"not found"}"#)
        }
    }

    /// Shared POST pipeline: decode, reject unsupported schema versions with
    /// 409, record the acceptance metric, hand the payload to the ingest
    /// closure fire-and-forget, and acknowledge with 202.
    private func ingest<Payload: VersionedIngressPayload>(
        _ type: Payload.Type,
        from request: LocalHTTPRequest,
        on clientSocket: Int32,
        invalidPayloadBody: String,
        recordAccepted: () -> Void,
        using ingest: @escaping @Sendable (Payload) async throws -> Void
    ) {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: request.body)
            guard payload.schemaVersion == Payload.supportedSchemaVersion else {
                sendJSON(clientSocket, status: 409, body: #"{"error":"unsupported schema"}"#)
                return
            }
            recordAccepted()
            Task {
                try? await ingest(payload)
            }
            sendJSON(clientSocket, status: 202, body: #"{"accepted":true}"#)
        } catch {
            sendJSON(clientSocket, status: 400, body: invalidPayloadBody)
        }
    }

    /// Length-independent-of-content comparison to avoid leaking the token via
    /// response timing. The length check is acceptable: the token length is fixed.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private func recordAcceptedOpenCodePayload() {
        lock.lock()
        acceptedOpenCodePayloadCount += 1
        lastOpenCodePayloadAt = .now
        lock.unlock()
    }

    private func recordAcceptedClaudeCodeEvent() {
        lock.lock()
        acceptedClaudeCodeEventCount += 1
        lastClaudeCodeEventAt = .now
        lock.unlock()
    }

    private func recordAcceptedClaudeCodeStatus() {
        lock.lock()
        acceptedClaudeCodeStatusCount += 1
        lastClaudeCodeEventAt = .now
        lock.unlock()
    }

    private func recordAcceptedCodexEvent() {
        lock.lock()
        acceptedCodexEventCount += 1
        lastCodexEventAt = .now
        lock.unlock()
    }

    private func healthJSON() -> String {
        lock.lock()
        let count = acceptedOpenCodePayloadCount
        let lastPayloadAt = lastOpenCodePayloadAt
        let claudeCodeCount = acceptedClaudeCodeEventCount
        let claudeCodeStatusCount = acceptedClaudeCodeStatusCount
        let lastClaudeEventAt = lastClaudeCodeEventAt
        let codexCount = acceptedCodexEventCount
        let latestCodexEventAt = lastCodexEventAt
        lock.unlock()

        var response: [String: Any] = [
            "ok": true,
            "schemaVersion": OpenCodePushPayload.supportedSchemaVersion,
            "service": "AgentHearth",
            "acceptedOpenCodePayloads": count,
            "acceptedClaudeCodeEvents": claudeCodeCount,
            "acceptedClaudeCodeStatuses": claudeCodeStatusCount,
            "acceptedCodexEvents": codexCount,
        ]
        if let lastPayloadAt {
            response["lastOpenCodePayloadAt"] = Int64(lastPayloadAt.timeIntervalSince1970 * 1_000)
        }
        if let lastClaudeEventAt {
            response["lastClaudeCodeEventAt"] = Int64(lastClaudeEventAt.timeIntervalSince1970 * 1_000)
        }
        if let latestCodexEventAt {
            response["lastCodexEventAt"] = Int64(latestCodexEventAt.timeIntervalSince1970 * 1_000)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false}"#
        }
        return json
    }

    private func sendJSON(_ socket: Int32, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        default: reason = "Error"
        }

        let response = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        let bytes = Array(response.utf8)
        _ = Darwin.send(socket, bytes, bytes.count, 0)
    }
}

/// Shared shape of the ingress POST payloads: each declares the schema version
/// it was produced with, checked against the version this build supports.
private protocol VersionedIngressPayload: Decodable, Sendable {
    static var supportedSchemaVersion: Int { get }
    var schemaVersion: Int { get }
}

extension OpenCodePushPayload: VersionedIngressPayload {}
extension CodexHookEvent: VersionedIngressPayload {}
extension ClaudeCodeHookEvent: VersionedIngressPayload {}
extension ClaudeCodeStatusEvent: VersionedIngressPayload {}
