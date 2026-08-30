import AgentHearthCore
import Foundation

/// Composes the provider-connector graph for the configured remote hosts and
/// OpenCode servers, so `AppModel` never names Infrastructure concretions.
struct ConnectorGraphBuilder {
    /// The zero-configuration local OpenCode connector, used unless an
    /// explicit local server replaces it.
    let automaticOpenCodeConnector: OpenCodeConnector

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
            let client = RemoteAgentClient(configuration: configuration)
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
            client: RemoteAgentClient(configuration: configuration)
        )
    }

    /// Fetches one preview snapshot per provider from a remote host, folding
    /// per-provider failures into degraded snapshots so the preview always
    /// shows every provider.
    func remotePreviewSnapshots(
        for configuration: RemoteHostConfiguration,
        modes: [AgentProviderID: ProviderDataSourceMode]
    ) async -> [ProviderSnapshot] {
        let client = RemoteAgentClient(configuration: configuration)
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
