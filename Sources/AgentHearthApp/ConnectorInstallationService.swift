import AgentHearthCore
import Foundation
import Observation

/// Owns the local connector installations — the OpenCode plugin and the Codex
/// and Claude Code hooks: their installation state, the bundled artifacts
/// they are installed from, and the user-facing outcome messages.
@MainActor
@Observable
final class ConnectorInstallationService {
    private let openCodeInstaller: OpenCodeConnectorInstaller
    private let codexInstaller: CodexConnectorInstaller
    private let claudeCodeInstaller: ClaudeCodeConnectorInstaller
    private let bundledOpenCodeConnectorURL: URL?
    private let bundledCodexHookURL: URL?
    private let bundledClaudeCodeHookURL: URL?

    var openCodeInstallationState: ConnectorInstallationState = .notInstalled
    var openCodeInstallationMessage: String?
    var codexInstallationState: ConnectorInstallationState = .notInstalled
    var codexInstallationMessage: String?
    var claudeCodeInstallationState: ConnectorInstallationState = .notInstalled
    var claudeCodeInstallationMessage: String?

    init(
        openCodeInstaller: OpenCodeConnectorInstaller,
        codexInstaller: CodexConnectorInstaller,
        claudeCodeInstaller: ClaudeCodeConnectorInstaller,
        bundledOpenCodeConnectorURL: URL?,
        bundledCodexHookURL: URL?,
        bundledClaudeCodeHookURL: URL?
    ) {
        self.openCodeInstaller = openCodeInstaller
        self.codexInstaller = codexInstaller
        self.claudeCodeInstaller = claudeCodeInstaller
        self.bundledOpenCodeConnectorURL = bundledOpenCodeConnectorURL
        self.bundledCodexHookURL = bundledCodexHookURL
        self.bundledClaudeCodeHookURL = bundledClaudeCodeHookURL
        refreshOpenCodeInstallationState()
        refreshCodexInstallationState()
        refreshClaudeCodeInstallationState()
    }

    func installOpenCodeConnector() {
        guard let bundledOpenCodeConnectorURL else {
            openCodeInstallationMessage = "The bundled OpenCode connector is missing."
            refreshOpenCodeInstallationState()
            return
        }

        do {
            try openCodeInstaller.install(from: bundledOpenCodeConnectorURL)
            openCodeInstallationMessage = "Installed. Restart OpenCode or start a new OpenCode session."
        } catch {
            openCodeInstallationMessage = error.localizedDescription
        }
        refreshOpenCodeInstallationState()
    }

    func refreshOpenCodeInstallationState() {
        openCodeInstallationState = openCodeInstaller.state(comparedWith: bundledOpenCodeConnectorURL)
    }

    func installCodexConnector() {
        guard let bundledCodexHookURL else {
            codexInstallationMessage = "The bundled Codex hook is missing."
            refreshCodexInstallationState()
            return
        }

        do {
            try codexInstaller.install(from: bundledCodexHookURL)
            codexInstallationMessage = "Installed without replacing existing hooks. Trust the hook when Codex asks, then start a new session."
        } catch {
            codexInstallationMessage = error.localizedDescription
        }
        refreshCodexInstallationState()
    }

    func refreshCodexInstallationState() {
        codexInstallationState = codexInstaller.state(comparedWith: bundledCodexHookURL)
    }

    func installClaudeCodeConnector() {
        guard let bundledClaudeCodeHookURL else {
            claudeCodeInstallationMessage = "The bundled Claude Code hook is missing."
            refreshClaudeCodeInstallationState()
            return
        }

        do {
            try claudeCodeInstaller.install(from: bundledClaudeCodeHookURL)
            claudeCodeInstallationMessage = "Installed without replacing existing hooks. Start a new Claude Code session."
        } catch {
            claudeCodeInstallationMessage = error.localizedDescription
        }
        refreshClaudeCodeInstallationState()
    }

    func refreshClaudeCodeInstallationState() {
        claudeCodeInstallationState = claudeCodeInstaller.state(comparedWith: bundledClaudeCodeHookURL)
    }

    /// Re-installs connectors that are already installed but older than the
    /// bundled copy. An outdated connector fails silently — the app rejects its
    /// posts and simply shows no realtime data — so waiting for the user to
    /// notice a badge in Settings loses live statuses and usage reset times for
    /// as long as it goes unseen. Only connectors the user already opted into
    /// are touched; a connector that is not installed stays that way.
    func updateOutdatedConnectors() {
        if openCodeInstallationState == .updateAvailable { installOpenCodeConnector() }
        if codexInstallationState == .updateAvailable { installCodexConnector() }
        if claudeCodeInstallationState == .updateAvailable { installClaudeCodeConnector() }
    }
}
