import AgentHearthCore
import Foundation
import Observation

struct RemoteHostPreview {
    let snapshots: [ProviderSnapshot]
    let refreshedAt: Date

    var sessions: [AgentSession] {
        snapshots.flatMap(\.sessions)
    }
}

/// Owns the configured SSH hosts and their whole lifecycle: registration,
/// agent install and uninstall, health checks, and session previews. Persists
/// exclusively through `PreferencesStore` and announces every topology change
/// through `onTopologyChanged`, so the composition root — not this service —
/// decides how the provider-connector graph reacts.
@MainActor
@Observable
final class RemoteHostsService {
    private let installer: RemoteAgentInstaller
    private let connectorGraph: ConnectorGraphBuilder
    private let preferences: PreferencesStore
    private let bundledRemoteAgentURL: URL?
    private let bundledOpenCodePluginURL: URL?

    /// Wired by the composition root: called once after any change to the
    /// host topology so the provider-connector graph can be rebuilt.
    @ObservationIgnored var onTopologyChanged: () -> Void = {}
    /// Wired by the composition root. Invariant: removing a remote host also
    /// removes that host's OpenCode servers. `removeRemoteHost` is the single
    /// place enforcing it, and this hook carries the removal into
    /// `OpenCodeServersService` without a back-reference.
    @ObservationIgnored var onHostRemoved: (String) -> Void = { _ in }
    /// Supplies the current per-provider data-source modes for previews.
    @ObservationIgnored var dataSourceModes: () -> [AgentProviderID: ProviderDataSourceMode] = { [:] }

    /// One token per host identifies the latest install/check/uninstall
    /// started for it. Completions compare against it so a slow earlier
    /// operation cannot overwrite the result of a later one, and a completion
    /// for a host that was removed meanwhile is dropped.
    @ObservationIgnored private var operationTokens: [String: UUID] = [:]

    var remoteHosts: [RemoteHostConfiguration] {
        didSet {
            guard remoteHosts != oldValue else { return }
            preferences.remoteHosts = remoteHosts
        }
    }
    var remoteHostStates: [String: RemoteAgentInstallationState] = [:]
    var remoteHostPreviews: [String: RemoteHostPreview] = [:]

    init(
        installer: RemoteAgentInstaller,
        connectorGraph: ConnectorGraphBuilder,
        preferences: PreferencesStore,
        bundledRemoteAgentURL: URL?,
        bundledOpenCodePluginURL: URL?
    ) {
        self.installer = installer
        self.connectorGraph = connectorGraph
        self.preferences = preferences
        self.bundledRemoteAgentURL = bundledRemoteAgentURL
        self.bundledOpenCodePluginURL = bundledOpenCodePluginURL
        self.remoteHosts = preferences.remoteHosts
    }

    /// Validates and registers a new SSH host. Returns a user-facing error
    /// message when the input is rejected, or nil once the host is added.
    func addRemoteHost(name: String, sshDestination: String) -> String? {
        let destination = sshDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SystemSSHCommandRunner.isValid(destination) else {
            return "Enter an SSH config alias or user@host."
        }
        guard !remoteHosts.contains(where: { $0.sshDestination == destination }) else {
            return "This SSH host is already configured."
        }
        let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = RemoteHostConfiguration(
            displayName: requestedName.isEmpty ? destination : requestedName,
            sshDestination: destination
        )
        remoteHosts.append(configuration)
        onTopologyChanged()
        checkRemoteHost(configuration)
        return nil
    }

    func setRemoteHost(_ hostID: String, enabled: Bool) {
        guard let index = remoteHosts.firstIndex(where: { $0.id == hostID }) else { return }
        remoteHosts[index].isEnabled = enabled
        onTopologyChanged()
    }

    func removeRemoteHost(_ hostID: String) {
        remoteHosts.removeAll { $0.id == hostID }
        remoteHostStates.removeValue(forKey: hostID)
        remoteHostPreviews.removeValue(forKey: hostID)
        operationTokens.removeValue(forKey: hostID)
        connectorGraph.forgetRemoteAgentClient(forHost: hostID)
        onHostRemoved(hostID)
        onTopologyChanged()
    }

    func installRemoteAgent(_ configuration: RemoteHostConfiguration) {
        guard let bundledRemoteAgentURL else {
            remoteHostStates[configuration.id] = .failed(message: "The bundled remote agent is missing.")
            return
        }
        let token = beginOperation(for: configuration)
        Task {
            do {
                let message = try await installer.install(
                    on: configuration,
                    scriptURL: bundledRemoteAgentURL,
                    openCodePluginURL: bundledOpenCodePluginURL,
                    client: connectorGraph.remoteAgentClient(for: configuration)
                )
                guard isCurrent(token, for: configuration) else { return }
                remoteHostStates[configuration.id] = .ready(message: message)
                await loadRemotePreview(configuration, token: token)
                guard isCurrent(token, for: configuration) else { return }
                onTopologyChanged()
            } catch {
                guard isCurrent(token, for: configuration) else { return }
                remoteHostStates[configuration.id] = .failed(message: error.localizedDescription)
            }
        }
    }

    func checkRemoteHost(_ configuration: RemoteHostConfiguration) {
        let token = beginOperation(for: configuration)
        Task {
            do {
                // Through the shared client so a green check also lifts the
                // backoff the polling connectors are honoring for this host.
                let message = try await installer.check(
                    configuration,
                    client: connectorGraph.remoteAgentClient(for: configuration)
                )
                guard isCurrent(token, for: configuration) else { return }
                remoteHostStates[configuration.id] = .ready(message: message)
                await loadRemotePreview(configuration, token: token)
            } catch {
                guard isCurrent(token, for: configuration) else { return }
                remoteHostStates[configuration.id] = .failed(message: error.localizedDescription)
                remoteHostPreviews.removeValue(forKey: configuration.id)
            }
        }
    }

    func uninstallRemoteAgent(_ configuration: RemoteHostConfiguration) {
        let token = beginOperation(for: configuration)
        Task {
            do {
                try await installer.uninstall(from: configuration)
                guard isCurrent(token, for: configuration) else { return }
                remoteHostStates[configuration.id] = .unknown
                remoteHostPreviews.removeValue(forKey: configuration.id)
            } catch {
                guard isCurrent(token, for: configuration) else { return }
                remoteHostStates[configuration.id] = .failed(message: error.localizedDescription)
            }
        }
    }

    private func beginOperation(for configuration: RemoteHostConfiguration) -> UUID {
        let token = UUID()
        operationTokens[configuration.id] = token
        remoteHostStates[configuration.id] = .checking
        return token
    }

    /// True while `token` is still the latest operation for a host that is
    /// still configured.
    private func isCurrent(_ token: UUID, for configuration: RemoteHostConfiguration) -> Bool {
        operationTokens[configuration.id] == token
            && remoteHosts.contains { $0.id == configuration.id }
    }

    private func loadRemotePreview(_ configuration: RemoteHostConfiguration, token: UUID) async {
        let snapshots = await connectorGraph.remotePreviewSnapshots(
            for: configuration,
            modes: dataSourceModes()
        )
        guard isCurrent(token, for: configuration) else { return }
        remoteHostPreviews[configuration.id] = RemoteHostPreview(
            snapshots: snapshots,
            refreshedAt: .now
        )
    }
}
