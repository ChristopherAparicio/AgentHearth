import AgentHearthCore
import SwiftUI

/// The OpenCode Connector section: the local plugin's installation card.
struct OpenCodeConnectorSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("OpenCode Connector") {
            ConnectorSettingsCard(
                title: "OpenCode local connector",
                symbol: "bolt.horizontal.circle",
                tint: .cyan,
                status: installationLabel,
                description: "Receives local OpenCode lifecycle events and cache telemetry. It never receives prompts, source files, or tool payloads.",
                detail: model.connectorServerError ?? "Local receiver ready on 127.0.0.1:5274",
                detailSymbol: model.connectorServerError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                detailColor: model.connectorServerError == nil ? .green : .red,
                primaryActionTitle: installButtonLabel,
                onPrimaryAction: model.connectorInstallation.installOpenCodeConnector,
                message: model.connectorInstallation.openCodeInstallationMessage,
                onRefresh: model.connectorInstallation.refreshOpenCodeInstallationState
            )
        }
    }

    private var installationLabel: String {
        switch model.connectorInstallation.openCodeInstallationState {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        case let .unavailable(reason): reason
        }
    }

    private var installButtonLabel: String {
        switch model.connectorInstallation.openCodeInstallationState {
        case .installed: "Reinstall"
        case .updateAvailable: "Update Connector"
        case .notInstalled, .unavailable: "Install Connector"
        }
    }
}

/// The Codex Connector section: the live-hooks installation card.
struct CodexConnectorSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Codex Connector") {
            ConnectorSettingsCard(
                title: "Codex live hooks",
                symbol: AgentProviderID.codex.symbolName,
                tint: AgentProviderID.codex.tint,
                status: installationLabel,
                description: "Local rollout analysis supplies cache tokens and quota windows. Hooks add immediate start, stop, and permission states without sending prompts or tool data.",
                primaryActionTitle: installButtonLabel,
                onPrimaryAction: model.connectorInstallation.installCodexConnector,
                message: model.connectorInstallation.codexInstallationMessage,
                onRefresh: model.connectorInstallation.refreshCodexInstallationState
            )
        }
    }

    private var installationLabel: String {
        switch model.connectorInstallation.codexInstallationState {
        case .notInstalled: "Optional · not installed"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        case let .unavailable(reason): reason
        }
    }

    private var installButtonLabel: String {
        switch model.connectorInstallation.codexInstallationState {
        case .installed: "Reinstall Hooks"
        case .updateAvailable: "Update Hooks"
        case .notInstalled, .unavailable: "Install Live Hooks"
        }
    }
}

/// The Claude Code Connector section: the live-hooks installation card.
struct ClaudeCodeConnectorSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Claude Code Connector") {
            ConnectorSettingsCard(
                title: "Claude Code live hooks",
                symbol: AgentProviderID.claudeCode.symbolName,
                tint: AgentProviderID.claudeCode.tint,
                status: installationLabel,
                description: "Cache and sessions are detected automatically. Hooks add precise states; the status-line relay adds 5-hour and 7-day usage windows without replacing an existing status line.",
                primaryActionTitle: installButtonLabel,
                onPrimaryAction: model.connectorInstallation.installClaudeCodeConnector,
                message: model.connectorInstallation.claudeCodeInstallationMessage,
                onRefresh: model.connectorInstallation.refreshClaudeCodeInstallationState
            )
        }
    }

    private var installationLabel: String {
        switch model.connectorInstallation.claudeCodeInstallationState {
        case .notInstalled: "Optional · not installed"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        case let .unavailable(reason): reason
        }
    }

    private var installButtonLabel: String {
        switch model.connectorInstallation.claudeCodeInstallationState {
        case .installed: "Reinstall Hooks"
        case .updateAvailable: "Update Hooks"
        case .notInstalled, .unavailable: "Install Live Hooks"
        }
    }
}

private struct ConnectorSettingsCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let status: String
    let description: String
    let detail: String?
    let detailSymbol: String?
    let detailColor: Color
    let primaryActionTitle: String
    let onPrimaryAction: () -> Void
    let message: String?
    let onRefresh: () -> Void

    init(
        title: String,
        symbol: String,
        tint: Color,
        status: String,
        description: String,
        detail: String? = nil,
        detailSymbol: String? = nil,
        detailColor: Color = .secondary,
        primaryActionTitle: String,
        onPrimaryAction: @escaping () -> Void,
        message: String? = nil,
        onRefresh: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.status = status
        self.description = description
        self.detail = detail
        self.detailSymbol = detailSymbol
        self.detailColor = detailColor
        self.primaryActionTitle = primaryActionTitle
        self.onPrimaryAction = onPrimaryAction
        self.message = message
        self.onRefresh = onRefresh
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(status, systemImage: "circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let detail {
                    Label(detail, systemImage: detailSymbol ?? "info.circle")
                        .font(.caption)
                        .foregroundStyle(detailColor)
                }

                HStack(spacing: 10) {
                    Button(primaryActionTitle, action: onPrimaryAction)
                        .buttonStyle(.borderedProminent)
                    Button("Check status", action: onRefresh)
                        .buttonStyle(.bordered)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(tint)
        }
    }
}
