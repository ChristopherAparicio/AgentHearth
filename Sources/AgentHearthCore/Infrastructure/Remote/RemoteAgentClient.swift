import AgentHearthApplication
import AgentHearthDomain
import Foundation

public enum RemoteAgentError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidResponse(String)
    /// The host failed recently and polling is paused until `retryAt`; the
    /// wrapped message is the last real error so the UI keeps showing its cause.
    case backingOff(retryAt: Date, lastError: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported remote AgentHearth schema: \(version)"
        case let .invalidResponse(message):
            return "Invalid response from the remote AgentHearth agent: \(message)"
        case let .backingOff(retryAt, lastError):
            let seconds = max(1, Int(retryAt.timeIntervalSinceNow.rounded(.up)))
            return "\(lastError) — retrying in \(seconds)s"
        }
    }
}

public actor RemoteAgentClient {
    public static let supportedSchemaVersion = 1
    public static let installedPath = "$HOME/.local/share/agenthearth/agenthearth_remote.py"

    /// Freshness window for a cached snapshot; each provider (and each
    /// OpenCode server) is judged only against its own fetch time.
    private static let snapshotFreshness: TimeInterval = 3

    /// Exponential backoff for an unreachable host: 10 s after the first
    /// failure, doubling up to three minutes. Without it every poll (as often
    /// as every 5 s while a local agent works) spawned three `ssh` processes
    /// per host that each hung for the connect timeout.
    static let initialBackoff: TimeInterval = 10
    static let maximumBackoff: TimeInterval = 180

    private struct CachedSnapshot {
        let snapshot: ProviderSnapshot
        let fetchedAt: Date
    }

    public let configuration: RemoteHostConfiguration
    private let runner: any SSHCommandRunning
    private let now: @Sendable () -> Date
    private var snapshotsByProvider: [AgentProviderID: CachedSnapshot] = [:]
    private var openCodeServerSnapshots: [String: CachedSnapshot] = [:]
    private var historyCursors: [AgentProviderID: Int64] = [:]
    private var historyFetchedAt: [AgentProviderID: Date] = [:]
    private var consecutiveFailures = 0
    private var suspendedUntil: Date?
    private var lastFailureAt: Date?
    private var lastFailureMessage = ""

    public init(
        configuration: RemoteHostConfiguration,
        runner: any SSHCommandRunning = SystemSSHCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.runner = runner
        self.now = now
    }

    public func health() async throws -> String {
        // An explicit health check is a user action: it always reaches the
        // host and, when it succeeds, lifts any pending backoff.
        let result = try await runRemote(
            "python3 \(Self.installedPath) health",
            standardInput: nil,
            bypassingBackoff: true
        )
        let health = try decodeEnvelope(RemoteAgentHealth.self, from: result.standardOutput)
        return "\(health.service) \(health.version) · \(health.status)"
    }

    /// Runs one command on the host, honoring and updating the backoff state.
    private func runRemote(
        _ remoteCommand: String,
        standardInput: Data?,
        bypassingBackoff: Bool = false
    ) async throws -> SSHCommandResult {
        let startedAt = now()
        if !bypassingBackoff, let suspendedUntil, startedAt < suspendedUntil {
            throw RemoteAgentError.backingOff(retryAt: suspendedUntil, lastError: lastFailureMessage)
        }
        do {
            let result = try await runner.run(
                destination: configuration.sshDestination,
                remoteCommand: remoteCommand,
                standardInput: standardInput
            )
            consecutiveFailures = 0
            suspendedUntil = nil
            lastFailureAt = nil
            return result
        } catch {
            // The three provider connectors of one host poll concurrently and
            // the actor is reentrant across the SSH call, so one outage yields
            // several failures at once. Only an attempt that began after the
            // previous failure escalates the backoff; its siblings just refresh
            // the deadline.
            if let lastFailureAt, startedAt <= lastFailureAt {
                // concurrent sibling of an already-counted failure
            } else {
                consecutiveFailures += 1
            }
            let exponent = Double(min(max(consecutiveFailures, 1) - 1, 10))
            let delay = min(Self.maximumBackoff, Self.initialBackoff * pow(2, exponent))
            let failedAt = now()
            lastFailureAt = failedAt
            suspendedUntil = failedAt.addingTimeInterval(delay)
            lastFailureMessage = error.localizedDescription
            throw error
        }
    }

    public func snapshot(
        for providerID: AgentProviderID,
        sourceMode: ProviderDataSourceMode
    ) async throws -> ProviderSnapshot {
        if let cached = snapshotsByProvider[providerID],
           now().timeIntervalSince(cached.fetchedAt) < Self.snapshotFreshness {
            return cached.snapshot
        }

        let result = try await runRemote(
            "python3 \(Self.installedPath) snapshot --provider \(providerID.remoteAgentArgument) --source \(sourceMode.rawValue)",
            standardInput: nil
        )
        let envelope = try decodeEnvelope(RemoteAgentEnvelope.self, from: result.standardOutput)
        let normalized = normalize(envelope)
        snapshotsByProvider[providerID] = CachedSnapshot(snapshot: normalized, fetchedAt: now())
        return normalized
    }

    public func openCodeServerSnapshot(
        _ server: OpenCodeServerConfiguration
    ) async throws -> ProviderSnapshot {
        if let cached = openCodeServerSnapshots[server.id],
           now().timeIntervalSince(cached.fetchedAt) < Self.snapshotFreshness {
            return cached.snapshot
        }

        guard (1...65_535).contains(server.port) else {
            throw OpenCodeServerError.invalidPort(server.port)
        }
        let result = try await runRemote(
            "python3 \(Self.installedPath) snapshot --provider opencode --source realtimeOnly --opencode-port \(server.port)",
            standardInput: nil
        )
        let envelope = try decodeEnvelope(RemoteAgentEnvelope.self, from: result.standardOutput)
        let normalized = normalize(envelope, source: server.source)
        openCodeServerSnapshots[server.id] = CachedSnapshot(snapshot: normalized, fetchedAt: now())
        return normalized
    }

    public func pendingHistoryEvents(for providerID: AgentProviderID) async throws -> [CacheHistoryImportEvent] {
        let fetchedAt = now()
        if let previous = historyFetchedAt[providerID], fetchedAt.timeIntervalSince(previous) < 60 {
            return []
        }
        historyFetchedAt[providerID] = fetchedAt
        let cursor = historyCursors[providerID] ?? 0
        let result = try await runRemote(
            "python3 \(Self.installedPath) history --provider \(providerID.remoteAgentArgument) --after-id \(cursor) --limit 2000",
            standardInput: nil
        )
        let envelope = try decodeEnvelope(RemoteAgentHistoryEnvelope.self, from: result.standardOutput)
        historyCursors[providerID] = max(cursor, envelope.nextCursor)
        let host = configuration.host
        return envelope.events.map { event in
            CacheHistoryImportEvent(
                externalID: "remote:\(host.id):\(event.id)",
                sessionKey: [providerID.rawValue, host.id, event.sessionId].joined(separator: ":"),
                sessionID: event.sessionId,
                providerID: event.provider,
                hostName: host.displayName,
                title: event.title,
                model: event.model,
                occurredAt: Self.date(event.occurredAt),
                hitCount: event.hitCount,
                missCount: event.missCount,
                coldStartCount: event.coldStartCount,
                unknownCount: event.unknownCount,
                currentHitCount: event.currentHitCount,
                currentMissCount: event.currentMissCount,
                currentColdStartCount: event.currentColdStartCount,
                currentUnknownCount: event.currentUnknownCount
            )
        }
    }

    private func normalize(
        _ envelope: RemoteAgentEnvelope,
        source: AgentSource? = nil
    ) -> ProviderSnapshot {
        let host = configuration.host
        let sessions = envelope.sessions.map { session in
            let directory = session.workingDirectory.map { URL(fileURLWithPath: $0) }
            let target = SessionTarget(
                providerID: envelope.provider,
                sessionID: session.id,
                workingDirectory: directory,
                host: host
            )
            return AgentSession(
                id: [host.id, envelope.provider.rawValue, source?.id, session.id]
                    .compactMap { $0 }
                    .joined(separator: ":"),
                providerID: envelope.provider,
                title: SessionTitle.normalized(session.title, fallback: session.id),
                projectName: session.projectName,
                model: session.model,
                status: session.status,
                lastActivityAt: Self.date(session.lastActivityAt),
                cache: CacheSnapshot(
                    temperature: session.cache.temperature,
                    remainingSeconds: session.cache.remainingSeconds,
                    ttlSeconds: session.cache.ttlSeconds,
                    inputTokens: session.cache.inputTokens,
                    outputTokens: session.cache.outputTokens,
                    cachedReadTokens: session.cache.cachedReadTokens,
                    cacheWriteTokens: session.cache.cacheWriteTokens,
                    lastConfirmedAt: session.cache.lastConfirmedAt.map(Self.date),
                    confidence: session.cache.confidence,
                    reason: session.cache.reason
                ),
                cacheHealth: session.cacheHealth.map {
                    CacheHealthSnapshot(
                        hitCount: $0.hitCount,
                        avoidableMissCount: $0.avoidableMissCount,
                        expectedColdStartCount: $0.expectedColdStartCount,
                        unknownCount: $0.unknownCount,
                        measuredAt: Self.date($0.measuredAt),
                        observedInputTokens: $0.observedInputTokens,
                        cachedInputTokens: $0.cachedInputTokens
                    )
                },
                target: target,
                host: host,
                source: source
            )
        }
        let windows = envelope.usageWindows.map {
            UsageWindow(
                id: "\(host.id):\($0.id)",
                label: "\($0.label) · \(host.displayName)",
                usedFraction: $0.usedFraction,
                resetsAt: $0.resetsAt.map(Self.date),
                measuredAt: Self.date($0.measuredAt),
                host: host
            )
        }
        let connectionState: ProviderConnectionState = if envelope.available {
            .connected
        } else if let message = envelope.message {
            .degraded(message: "\(host.displayName): \(message)")
        } else {
            .unavailable
        }
        return ProviderSnapshot(
            id: envelope.provider,
            connectionState: connectionState,
            sessions: sessions,
            usageWindows: windows,
            updatedAt: Self.date(envelope.updatedAt)
        )
    }

    /// Decodes one remote envelope, wrapping decode failures as
    /// `invalidResponse` and rejecting any schema version this build does not
    /// support.
    private func decodeEnvelope<Envelope: RemoteAgentVersionedEnvelope>(
        _ type: Envelope.Type,
        from data: Data
    ) throws -> Envelope {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder.agentHearthRemote().decode(Envelope.self, from: data)
        } catch {
            throw RemoteAgentError.invalidResponse(error.localizedDescription)
        }
        guard envelope.schemaVersion == Self.supportedSchemaVersion else {
            throw RemoteAgentError.unsupportedSchema(envelope.schemaVersion)
        }
        return envelope
    }

    // Kept as a point-free adapter over the shared conversion for the many
    // `.map(Self.date)` call sites above.
    private static func date(_ milliseconds: Int64) -> Date {
        Date(millisecondsSince1970: milliseconds)
    }
}

private protocol RemoteAgentVersionedEnvelope: Decodable {
    var schemaVersion: Int { get }
}

extension RemoteAgentHealth: RemoteAgentVersionedEnvelope {}
extension RemoteAgentEnvelope: RemoteAgentVersionedEnvelope {}
extension RemoteAgentHistoryEnvelope: RemoteAgentVersionedEnvelope {}

private extension AgentProviderID {
    /// The `--provider` argument understood by `agenthearth_remote.py`.
    var remoteAgentArgument: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude-code"
        case .openCode: "opencode"
        }
    }
}

public actor RemoteOpenCodeServerConnector: ProviderConnector, ProviderHistoryConnector {
    public nonisolated let providerID = AgentProviderID.openCode
    private let server: OpenCodeServerConfiguration
    private let client: RemoteAgentClient

    public init(server: OpenCodeServerConfiguration, client: RemoteAgentClient) {
        self.server = server
        self.client = client
    }

    public func setSourceMode(_: ProviderDataSourceMode) {}

    public func snapshot() async throws -> ProviderSnapshot {
        return try await client.openCodeServerSnapshot(server)
    }

    public func pendingHistoryEvents() async throws -> [CacheHistoryImportEvent] {
        try await client.pendingHistoryEvents(for: .openCode)
    }
}

public actor RemoteProviderConnector: ProviderConnector, ProviderHistoryConnector {
    public nonisolated let providerID: AgentProviderID
    private let client: RemoteAgentClient
    private var sourceMode = ProviderDataSourceMode.automatic

    public init(providerID: AgentProviderID, client: RemoteAgentClient) {
        self.providerID = providerID
        self.client = client
    }

    public func setSourceMode(_ mode: ProviderDataSourceMode) {
        sourceMode = mode
    }

    public func snapshot() async throws -> ProviderSnapshot {
        try await client.snapshot(for: providerID, sourceMode: sourceMode)
    }

    public func pendingHistoryEvents() async throws -> [CacheHistoryImportEvent] {
        try await client.pendingHistoryEvents(for: providerID)
    }
}
