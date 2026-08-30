import AgentHearthApplication
import AgentHearthDomain
import Foundation

public enum OpenCodeServerError: LocalizedError {
    case invalidPort(Int)
    case invalidResponse
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port): "Invalid OpenCode server port: \(port)"
        case .invalidResponse: "The OpenCode server returned an invalid response."
        case let .requestFailed(status): "The OpenCode server returned HTTP \(status)."
        }
    }
}

public protocol OpenCodeServerLoading: Sendable {
    func load(path: String, port: Int) async throws -> Data
}

public struct LoopbackOpenCodeServerLoader: OpenCodeServerLoading {
    public init() {}

    public func load(path: String, port: Int) async throws -> Data {
        guard (1...65_535).contains(port) else { throw OpenCodeServerError.invalidPort(port) }
        guard var components = URLComponents(string: "http://127.0.0.1:\(port)") else {
            throw OpenCodeServerError.invalidResponse
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw OpenCodeServerError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw OpenCodeServerError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeServerError.requestFailed(response.statusCode)
        }
        return data
    }
}

/// Reads a specific OpenCode HTTP server. Only loopback is supported here;
/// remote servers use `RemoteOpenCodeServerConnector` over SSH.
public actor OpenCodeServerConnector: ProviderConnector {
    public nonisolated let providerID = AgentProviderID.openCode

    private let configuration: OpenCodeServerConfiguration
    private let host: AgentHost
    private let loader: any OpenCodeServerLoading
    private let relevantAge: TimeInterval
    private let stuckAfter: TimeInterval
    private let now: @Sendable () -> Date
    private var messageCache: [String: MessageCacheEntry] = [:]

    public init(
        configuration: OpenCodeServerConfiguration,
        host: AgentHost = .local,
        loader: any OpenCodeServerLoading = LoopbackOpenCodeServerLoader(),
        relevantAge: TimeInterval = 7 * 24 * 60 * 60,
        stuckAfter: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.host = host
        self.loader = loader
        self.relevantAge = relevantAge
        self.stuckAfter = stuckAfter
        self.now = now
    }

    public func setSourceMode(_: ProviderDataSourceMode) {}

    public func snapshot() async throws -> ProviderSnapshot {
        async let sessionsData = loader.load(path: "/session", port: configuration.port)
        async let statusesData = loader.load(path: "/session/status", port: configuration.port)
        let decoder = JSONDecoder()
        let sessionsPayload = try await sessionsData
        let statusesPayload = try? await statusesData
        let apiSessions = try decoder.decode([APISession].self, from: sessionsPayload)
        let statuses = statusesPayload.flatMap {
            try? decoder.decode([String: APIStatus].self, from: $0)
        } ?? [:]
        let cutoff = now().addingTimeInterval(-relevantAge)
        let candidates = apiSessions
            .filter {
                $0.parentID == nil && Date(millisecondsSince1970: $0.time.updated) >= cutoff
            }
            .sorted { $0.time.updated > $1.time.updated }
            .prefix(50)

        var messagesBySession: [String: [APIMessage]] = [:]
        for session in candidates {
            if let cached = messageCache[session.id], cached.updatedAt == session.time.updated {
                messagesBySession[session.id] = cached.messages
            }
        }
        let refreshed = await withTaskGroup(
            of: (String, Int64, [APIMessage]).self,
            returning: [(String, Int64, [APIMessage])].self
        ) { group in
            for session in candidates where messagesBySession[session.id] == nil {
                group.addTask { [loader, configuration] in
                    let encodedID = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                        ?? session.id
                    let messages: [APIMessage]
                    do {
                        let data = try await loader.load(
                            path: "/session/\(encodedID)/message",
                            port: configuration.port
                        )
                        messages = try JSONDecoder().decode([APIMessage].self, from: data)
                    } catch {
                        messages = []
                    }
                    return (session.id, session.time.updated, messages)
                }
            }
            var values: [(String, Int64, [APIMessage])] = []
            for await value in group { values.append(value) }
            return values
        }
        for (sessionID, updatedAt, messages) in refreshed {
            messagesBySession[sessionID] = messages
            messageCache[sessionID] = MessageCacheEntry(updatedAt: updatedAt, messages: messages)
        }
        let candidateIDs = Set(candidates.map(\.id))
        messageCache = messageCache.filter { candidateIDs.contains($0.key) }

        let sessions: [AgentSession] = candidates.compactMap { session in
            Self.normalize(
                session,
                messages: messagesBySession[session.id] ?? [],
                serverStatus: statuses[session.id],
                configuration: configuration,
                host: host,
                stuckAfter: stuckAfter,
                now: now()
            )
        }
        .sortedWorkingFirst()

        return ProviderSnapshot(
            id: providerID,
            connectionState: .connected,
            sessions: sessions,
            usageWindows: [],
            updatedAt: sessions.map(\.lastActivityAt).max() ?? now()
        )
    }

    private static func normalize(
        _ session: APISession,
        messages: [APIMessage],
        serverStatus: APIStatus?,
        configuration: OpenCodeServerConfiguration,
        host: AgentHost,
        stuckAfter: TimeInterval,
        now: Date
    ) -> AgentSession? {
        let infos = messages.map(\.info)
        let latest = infos.last
        let assistants = infos.filter { $0.role == "assistant" }
        let latestAssistant = assistants.last
        let updatedAt = Date(millisecondsSince1970: session.time.updated)
        let activityAt = max(updatedAt, latest?.activityAt ?? .distantPast)
        let status: SessionStatus
        if latestAssistant?.error != nil || latestAssistant?.finish == "error" {
            status = .failed
        } else if serverStatus?.type == "busy" || serverStatus?.type == "retry" {
            status = now.timeIntervalSince(activityAt) >= stuckAfter ? .stuck : .working
        } else {
            status = .idle
        }

        let provider = latestAssistant?.providerID ?? session.model?.providerID
        let model = latestAssistant?.modelID ?? session.model?.id
        let confirmedAt = latestAssistant?.completedAt ?? latestAssistant?.createdAt
        let expiry = OpenCodeCacheExpiry(
            provider: provider,
            model: model,
            confirmedAt: confirmedAt,
            now: now
        )
        let read = max(0, latestAssistant?.tokens?.cache?.read ?? 0)
        let write = max(0, latestAssistant?.tokens?.cache?.write ?? 0)
        let health = cacheHealth(assistants, measuredAt: activityAt)
        guard status == .working || status.requiresAttention
                || expiry.temperature == .warm || expiry.temperature == .expiring
        else { return nil }

        let directory = URL(fileURLWithPath: session.directory)
        return AgentSession(
            id: "\(host.id):opencode:\(configuration.id):\(session.id)",
            providerID: .openCode,
            title: session.title.isEmpty ? session.id : session.title,
            projectName: directory.lastPathComponent,
            model: model,
            status: status,
            lastActivityAt: activityAt,
            cache: CacheSnapshot(
                temperature: expiry.temperature,
                remainingSeconds: expiry.remainingSeconds,
                ttlSeconds: expiry.ttlSeconds,
                inputTokens: latestAssistant?.tokens?.input,
                outputTokens: latestAssistant?.tokens?.output,
                cachedReadTokens: read,
                cacheWriteTokens: write,
                lastConfirmedAt: read > 0 ? confirmedAt : nil,
                confidence: read > 0 ? .observed : .inferred,
                reason: "OpenCode server telemetry from 127.0.0.1:\(configuration.port)"
            ),
            cacheHealth: health,
            target: SessionTarget(
                providerID: .openCode,
                sessionID: session.id,
                workingDirectory: directory,
                host: host
            ),
            host: host,
            source: configuration.source
        )
    }

    /// Assistant messages without token telemetry count as unknown but still
    /// become the reference turn; a miss is avoidable only when the previous
    /// turn used the same provider and model.
    private static func cacheHealth(
        _ assistants: [APIMessageInfo],
        measuredAt: Date
    ) -> CacheHealthSnapshot? {
        var evidence = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .currentTurn, requiresStableModel: true)
        )
        for message in assistants {
            evidence.observe(CacheEvidenceAccumulator.TurnObservation(
                startedAt: message.createdAt,
                endedAt: message.completedAt,
                hasTokenTelemetry: message.tokens != nil,
                cachedReadTokens: message.tokens?.cache?.read ?? 0,
                ttl: TimeInterval(
                    CacheTTLPolicy.ttlSeconds(provider: message.providerID, model: message.modelID)
                ),
                providerID: message.providerID,
                modelID: message.modelID
            ))
        }
        return evidence.snapshot(measuredAt: measuredAt)
    }
}

private struct APISession: Decodable, Sendable {
    struct TimeValue: Decodable, Sendable { let updated: Int64 }
    struct ModelValue: Decodable, Sendable { let id: String; let providerID: String }

    let id: String
    let title: String
    let directory: String
    let parentID: String?
    let model: ModelValue?
    let time: TimeValue
}

private struct APIStatus: Decodable, Sendable {
    let type: String
}

private struct APIMessage: Decodable, Sendable {
    let info: APIMessageInfo
}

private struct MessageCacheEntry: Sendable {
    let updatedAt: Int64
    let messages: [APIMessage]
}

private struct APIMessageInfo: Decodable, Sendable {
    struct TimeValue: Decodable, Sendable {
        let created: Int64?
        let completed: Int64?
    }
    struct TokenValue: Decodable, Sendable {
        struct CacheValue: Decodable, Sendable { let read: Int?; let write: Int? }
        let input: Int?
        let output: Int?
        let cache: CacheValue?
    }

    let role: String?
    let providerID: String?
    let modelID: String?
    let time: TimeValue?
    let error: JSONValue?
    let finish: String?
    let tokens: TokenValue?

    var createdAt: Date? {
        time?.created.map { Date(millisecondsSince1970: $0) }
    }

    var completedAt: Date? {
        time?.completed.map { Date(millisecondsSince1970: $0) }
    }

    var activityAt: Date? { completedAt ?? createdAt }
}

/// We only need to know whether an API error value exists; its content is not
/// retained or exposed.
private enum JSONValue: Decodable, Sendable {
    case present

    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer().decode(Bool.self)
        self = .present
    }
}
