import AgentHearthCore
import Foundation
import Observation

enum OpenCodeServerConnectionState: Equatable {
    case unknown
    case checking
    case ready(sessionCount: Int)
    case failed(message: String)
}

/// Owns the explicitly configured OpenCode servers: registration, enablement,
/// removal, and connection checks. Persists exclusively through
/// `PreferencesStore` and announces every topology change through
/// `onTopologyChanged`, so the composition root decides how the
/// provider-connector graph reacts.
@MainActor
@Observable
final class OpenCodeServersService {
    private let connectorGraph: ConnectorGraphBuilder
    private let preferences: PreferencesStore

    /// Wired by the composition root: called once after any change to the
    /// server topology so the provider-connector graph can be rebuilt.
    @ObservationIgnored var onTopologyChanged: () -> Void = {}
    /// Wired by the composition root: lets UI state (the menu-bar server
    /// selection) react to a server disappearing.
    @ObservationIgnored var onServerRemoved: (String) -> Void = { _ in }
    /// Supplies the currently configured SSH hosts for validation and for
    /// building remote-server connectors.
    @ObservationIgnored var remoteHosts: () -> [RemoteHostConfiguration] = { [] }

    var openCodeServers: [OpenCodeServerConfiguration] {
        didSet {
            guard openCodeServers != oldValue else { return }
            preferences.openCodeServers = openCodeServers
        }
    }
    var openCodeServerStates: [String: OpenCodeServerConnectionState] = [:]

    init(connectorGraph: ConnectorGraphBuilder, preferences: PreferencesStore) {
        self.connectorGraph = connectorGraph
        self.preferences = preferences
        self.openCodeServers = preferences.openCodeServers
    }

    /// Validates and registers a new OpenCode server. Returns a user-facing
    /// error message when the input is rejected, or nil once the server is added.
    func addOpenCodeServer(name: String, hostID: String, port: String) -> String? {
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(port), (1...65_535).contains(port) else {
            return "Enter a port between 1 and 65535."
        }
        guard hostID == AgentHost.local.id
                || remoteHosts().contains(where: { $0.id == hostID })
        else {
            return "Select an available machine."
        }
        guard !openCodeServers.contains(where: {
            $0.hostID == hostID && $0.port == port
        }) else {
            return "This OpenCode server is already configured."
        }
        let hostName = hostDisplayName(for: hostID) ?? "OpenCode"
        let server = OpenCodeServerConfiguration(
            displayName: requestedName.isEmpty ? "\(hostName) · :\(port)" : requestedName,
            hostID: hostID,
            port: port
        )
        openCodeServers.append(server)
        onTopologyChanged()
        checkOpenCodeServer(server)
        return nil
    }

    func setOpenCodeServer(_ serverID: String, enabled: Bool) {
        guard let index = openCodeServers.firstIndex(where: { $0.id == serverID }) else { return }
        openCodeServers[index].isEnabled = enabled
        onTopologyChanged()
    }

    func removeOpenCodeServer(_ serverID: String) {
        openCodeServers.removeAll { $0.id == serverID }
        openCodeServerStates.removeValue(forKey: serverID)
        onServerRemoved(serverID)
        onTopologyChanged()
    }

    func checkOpenCodeServer(_ server: OpenCodeServerConfiguration) {
        openCodeServerStates[server.id] = .checking
        guard let connector = connectorGraph.openCodeServerConnector(for: server, remoteHosts: remoteHosts()) else {
            openCodeServerStates[server.id] = .failed(message: "The selected SSH host is unavailable.")
            return
        }
        Task {
            do {
                await connector.setSourceMode(.automatic)
                let snapshot = try await connector.snapshot()
                openCodeServerStates[server.id] = .ready(sessionCount: snapshot.sessions.count)
            } catch {
                openCodeServerStates[server.id] = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Mutation primitive for the remove-a-host invariant owned by
    /// `RemoteHostsService.removeRemoteHost`: drops that host's servers
    /// without triggering a topology rebuild of its own, so the removal
    /// rebuilds the connector graph exactly once.
    func removeServers(forHost hostID: String) {
        openCodeServers.removeAll { $0.hostID == hostID }
    }

    private func hostDisplayName(for hostID: String) -> String? {
        if hostID == AgentHost.local.id { return AgentHost.local.displayName }
        return remoteHosts().first { $0.id == hostID }?.host.displayName
    }
}
