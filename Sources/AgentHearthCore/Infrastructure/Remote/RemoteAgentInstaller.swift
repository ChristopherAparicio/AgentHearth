import AgentHearthApplication
import AgentHearthDomain
import Foundation

public enum RemoteAgentInstallationState: Equatable, Sendable {
    case unknown
    case checking
    case ready(message: String)
    case failed(message: String)
}

public actor RemoteAgentInstaller {
    private let runner: any SSHCommandRunning

    public init(runner: any SSHCommandRunning = SystemSSHCommandRunner()) {
        self.runner = runner
    }

    /// - Parameter client: the host's shared `RemoteAgentClient` when the caller
    ///   has one; the final health check then also clears that client's
    ///   failure backoff. A throwaway client is used otherwise.
    public func install(
        on configuration: RemoteHostConfiguration,
        scriptURL: URL,
        openCodePluginURL: URL? = nil,
        client: RemoteAgentClient? = nil
    ) async throws -> String {
        let script = try Data(contentsOf: scriptURL)
        let installCommand = "umask 077; mkdir -p \"$HOME/.local/share/agenthearth\" && cat > \"$HOME/.local/share/agenthearth/agenthearth_remote.py\" && chmod 700 \"$HOME/.local/share/agenthearth/agenthearth_remote.py\" && python3 \"$HOME/.local/share/agenthearth/agenthearth_remote.py\" install-service"
        _ = try await runner.run(
            destination: configuration.sshDestination,
            remoteCommand: installCommand,
            standardInput: script
        )
        if let openCodePluginURL {
            let plugin = try Data(contentsOf: openCodePluginURL)
            let pluginCommand = "umask 077; mkdir -p \"$HOME/.config/opencode/plugins\" && cat > \"$HOME/.config/opencode/plugins/agenthearth.ts\" && chmod 600 \"$HOME/.config/opencode/plugins/agenthearth.ts\""
            _ = try await runner.run(
                destination: configuration.sshDestination,
                remoteCommand: pluginCommand,
                standardInput: plugin
            )
        }
        let client = client ?? RemoteAgentClient(configuration: configuration, runner: runner)
        return try await client.health()
    }

    public func check(
        _ configuration: RemoteHostConfiguration,
        client: RemoteAgentClient? = nil
    ) async throws -> String {
        let client = client ?? RemoteAgentClient(configuration: configuration, runner: runner)
        return try await client.health()
    }

    public func uninstall(from configuration: RemoteHostConfiguration) async throws {
        let command = "if [ -f \"$HOME/.local/share/agenthearth/agenthearth_remote.py\" ]; then python3 \"$HOME/.local/share/agenthearth/agenthearth_remote.py\" uninstall && rm -f \"$HOME/.local/share/agenthearth/agenthearth_remote.py\"; fi; rmdir \"$HOME/.local/share/agenthearth\" 2>/dev/null || true"
        _ = try await runner.run(
            destination: configuration.sshDestination,
            remoteCommand: command,
            standardInput: nil
        )
    }
}
