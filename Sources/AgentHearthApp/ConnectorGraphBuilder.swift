import AgentHearthCore
import Foundation

/// Composes the provider-connector graph for the configured remote hosts and
/// OpenCode servers, so `AppModel` never names Infrastructure concretions.
/// Main-actor bound like every service that holds it.
@MainActor
struct ConnectorGraphBuilder {
    /// The zero-configuration local OpenCode connector, used unless an
    /// explicit local server replaces it.
    let automaticOpenCodeConnector: OpenCodeConnector

    /// One `RemoteAgentClient` per host, shared by the polling connectors, the
    /// Settings previews, and the install/check actions. Sharing matters
    /// because the client owns the host's failure backoff: a successful
    /// **Test Connection** must clear the same backoff the poller is honoring.
    /// Reference type so every copy of this struct sees the same cache; only
    /// touched from `@MainActor` callers.
    private final class RemoteAgentClientCache {
        var clients: [String: (destination: String, client: RemoteAgentClient)] = [:]
    }

    private let clientCache = RemoteAgentClientCache()

    init(automaticOpenCodeConnector: OpenCodeConnector) {
        self.automaticOpenCodeConnector = automaticOpenCodeConnector
    }

    /// Returns the host's shared client, replacing it when the SSH destination
    /// changed since it was created.
    func remoteAgentClient(for configuration: RemoteHostConfiguration) -> RemoteAgentClient {
        if let cached = clientCache.clients[configuration.id],
           cached.destination == configuration.sshDestination {
            return cached.client
        }
        let client = RemoteAgentClient(configuration: configuration)
        clientCache.clients[configuration.id] = (configuration.sshDestination, client)
        return client
    }

    func forgetRemoteAgentClient(forHost hostID: String) {
        clientCache.clients.removeValue(forKey: hostID)
    }

    func additionalConnectors(
        remoteHosts: [RemoteHostConfiguration],
        openCodeServers: [OpenCodeServerConfiguration]
    ) -> [any ProviderConnector] {
        let enabledServers = openCodeServers.filter(\.isEnabled)
        var connectors: [any ProviderConnector] = []
        if !enabledServers.contains(where: { $0.hostID == AgentHost.local.id }) {
            connectors.append(automaticOpenCodeConnector)
        }

        for configuration in remoteHosts.filter(\.isEnabled) {
            let client = remoteAgentClient(for: configuration)
            connectors.append(RemoteProviderConnector(providerID: .codex, client: client))
            connectors.append(RemoteProviderConnector(providerID: .claudeCode, client: client))
            let servers = enabledServers.filter { $0.hostID == configuration.id }
            if servers.isEmpty {
                connectors.append(RemoteProviderConnector(providerID: .openCode, client: client))
            } else {
                connectors.append(contentsOf: servers.map {
                    RemoteOpenCodeServerConnector(server: $0, client: client) as any ProviderConnector
                })
            }
        }

        connectors.append(contentsOf: enabledServers.compactMap { server in
            guard server.hostID == AgentHost.local.id else { return nil }
            return OpenCodeServerConnector(configuration: server) as any ProviderConnector
        })
        return connectors
    }

    func openCodeServerConnector(
        for server: OpenCodeServerConfiguration,
        remoteHosts: [RemoteHostConfiguration]
    ) -> (any ProviderConnector)? {
        if server.hostID == AgentHost.local.id {
            return OpenCodeServerConnector(configuration: server)
        }
        guard let configuration = remoteHosts.first(where: { $0.id == server.hostID }) else {
            return nil
        }
        return RemoteOpenCodeServerConnector(
            server: server,
            client: remoteAgentClient(for: configuration)
        )
    }

    /// Fetches one preview snapshot per provider from a remote host, folding
    /// per-provider failures into degraded snapshots so the preview always
    /// shows every provider.
    func remotePreviewSnapshots(
        for configuration: RemoteHostConfiguration,
        modes: [AgentProviderID: ProviderDataSourceMode]
    ) async -> [ProviderSnapshot] {
        let client = remoteAgentClient(for: configuration)
        return await withTaskGroup(
            of: ProviderSnapshot.self,
            returning: [ProviderSnapshot].self
        ) { group in
            for providerID in AgentProviderID.allCases {
                group.addTask {
                    do {
                        return try await client.snapshot(
                            for: providerID,
                            sourceMode: modes[providerID] ?? .automatic
                        )
                    } catch {
                        return ProviderSnapshot(
                            id: providerID,
                            connectionState: .degraded(message: error.localizedDescription),
                            sessions: [],
                            usageWindows: []
                        )
                    }
                }
            }
            var values: [ProviderSnapshot] = []
            for await snapshot in group {
                values.append(snapshot)
            }
            return values.sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }
}
