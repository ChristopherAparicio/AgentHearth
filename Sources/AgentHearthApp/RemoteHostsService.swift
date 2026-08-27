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
        onHostRemoved(hostID)
        onTopologyChanged()
    }

    func installRemoteAgent(_ configuration: RemoteHostConfiguration) {
        guard let bundledRemoteAgentURL else {
            remoteHostStates[configuration.id] = .failed(message: "The bundled remote agent is missing.")
            return
        }
        remoteHostStates[configuration.id] = .checking
        Task {
            do {
                let message = try await installer.install(
                    on: configuration,
                    scriptURL: bundledRemoteAgentURL,
                    openCodePluginURL: bundledOpenCodePluginURL
                )
                remoteHostStates[configuration.id] = .ready(message: message)
                await loadRemotePreview(configuration)
                onTopologyChanged()
            } catch {
                remoteHostStates[configuration.id] = .failed(message: error.localizedDescription)
            }
        }
    }

    func checkRemoteHost(_ configuration: RemoteHostConfiguration) {
        remoteHostStates[configuration.id] = .checking
        Task {
            do {
                let message = try await installer.check(configuration)
                remoteHostStates[configuration.id] = .ready(message: message)
                await loadRemotePreview(configuration)
            } catch {
                remoteHostStates[configuration.id] = .failed(message: error.localizedDescription)
                remoteHostPreviews.removeValue(forKey: configuration.id)
            }
        }
    }

    func uninstallRemoteAgent(_ configuration: RemoteHostConfiguration) {
        remoteHostStates[configuration.id] = .checking
        Task {
            do {
                try await installer.uninstall(from: configuration)
                remoteHostStates[configuration.id] = .unknown
                remoteHostPreviews.removeValue(forKey: configuration.id)
            } catch {
                remoteHostStates[configuration.id] = .failed(message: error.localizedDescription)
            }
        }
    }

    private func loadRemotePreview(_ configuration: RemoteHostConfiguration) async {
        let snapshots = await connectorGraph.remotePreviewSnapshots(
            for: configuration,
            modes: dataSourceModes()
        )
        remoteHostPreviews[configuration.id] = RemoteHostPreview(
            snapshots: snapshots,
            refreshedAt: .now
        )
    }
}
