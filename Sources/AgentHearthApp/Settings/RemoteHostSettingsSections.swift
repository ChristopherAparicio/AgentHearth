import AgentHearthCore
import SwiftUI

/// The Remote Hosts section: configured SSH hosts with install, test,
/// uninstall, and remove controls plus the add-host form.
struct RemoteHostsSettingsSection: View {
    let model: AppModel
    @Binding var pendingRemoteUninstall: RemoteHostConfiguration?

    var body: some View {
        Section("Remote Hosts") {
            ForEach(model.remoteHostsService.remoteHosts) { host in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { host.isEnabled },
                            set: { model.remoteHostsService.setRemoteHost(host.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.displayName)
                                Text(host.sshDestination)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Text(remoteStateLabel(for: host.id))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(remoteStateColor(for: host.id))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                remoteStateColor(for: host.id).opacity(0.12),
                                in: Capsule()
                            )
                    }

                    HStack(spacing: 10) {
                        Button("Install / Update Agent") {
                            model.remoteHostsService.installRemoteAgent(host)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Test Connection") {
                            model.remoteHostsService.checkRemoteHost(host)
                        }
                        .buttonStyle(.bordered)
                        Button("Uninstall Agent", role: .destructive) {
                            pendingRemoteUninstall = host
                        }
                        .buttonStyle(.bordered)
                        Button("Remove", role: .destructive) {
                            model.remoteHostsService.removeRemoteHost(host.id)
                        }
                        .buttonStyle(.borderless)
                    }

                    if let preview = model.remoteHostsService.remoteHostPreviews[host.id] {
                        remotePreview(preview)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            AddRemoteHostForm(model: model)

            Text("Install / Update Agent also installs the bundled OpenCode plugin. AgentHearth uses /usr/bin/ssh and your existing ~/.ssh/config. The remote agent listens only on 127.0.0.1 and sends normalized metadata—never prompts, responses, tool payloads, or source files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func remoteStateLabel(for hostID: String) -> String {
        switch model.remoteHostsService.remoteHostStates[hostID] ?? .unknown {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case let .ready(message): message
        case let .failed(message): message
        }
    }

    private func remoteStateColor(for hostID: String) -> Color {
        switch model.remoteHostsService.remoteHostStates[hostID] ?? .unknown {
        case .ready: .green
        case .failed: .red
        case .unknown, .checking: .secondary
        }
    }

    private func remotePreview(_ preview: RemoteHostPreview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()

            HStack(spacing: 7) {
                ForEach(preview.snapshots) { snapshot in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(remoteConnectionColor(snapshot.connectionState))
                            .frame(width: 6, height: 6)
                        Text(snapshot.id.displayName)
                        Text("\(snapshot.sessions.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.65), in: Capsule())
                }

                Spacer()

                Text("checked \(preview.refreshedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if preview.sessions.isEmpty {
                Text("Connected · no active or warm-cache session detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(preview.sessions.prefix(6))) { session in
                    HStack(spacing: 7) {
                        Image(systemName: session.providerID.symbolName)
                            .foregroundStyle(session.providerID.tint)
                            .frame(width: 15)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                if let project = session.projectName {
                                    Text(project)
                                }
                                Text(session.status.label)
                                    .foregroundStyle(session.status.tint)
                                Text(session.cache.displayText)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let target = session.target {
                            Button {
                                model.openSession(target)
                            } label: {
                                Image(systemName: "arrow.up.forward")
                            }
                            .buttonStyle(.borderless)
                            .help("Resume this remote session")
                        }
                    }
                }

                if preview.sessions.count > 6 {
                    Text("+ \(preview.sessions.count - 6) more sessions in the menu bar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
    }

    private func remoteConnectionColor(_ state: ProviderConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .degraded: .orange
        case .unavailable: .secondary
        }
    }
}

/// The OpenCode Servers section: explicit loopback servers with test and
/// remove controls plus the add-server form.
struct OpenCodeServersSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("OpenCode Servers") {
            if model.openCodeServersService.openCodeServers.isEmpty {
                Label("No explicit server configured", systemImage: "server.rack")
                    .foregroundStyle(.secondary)
                Text("AgentHearth currently uses automatic local discovery. Add servers when several OpenCode instances run on the same machine or over SSH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.openCodeServersService.openCodeServers) { server in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.cyan.opacity(0.12))
                        Image(systemName: server.hostID == AgentHost.local.id
                              ? "laptopcomputer" : "network")
                            .foregroundStyle(.cyan)
                    }
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(isOn: Binding(
                            get: { server.isEnabled },
                            set: { model.openCodeServersService.setOpenCodeServer(server.id, enabled: $0) }
                        )) {
                            HStack(spacing: 7) {
                                Text(server.displayName)
                                    .fontWeight(.medium)
                                Text(serverStateLabel(server.id))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(serverStateColor(server.id))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        serverStateColor(server.id).opacity(0.10),
                                        in: Capsule()
                                    )
                            }
                        }

                        Text("\(model.host(for: server.hostID)?.displayName ?? "Unknown machine") · 127.0.0.1:\(server.port)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button("Test") { model.openCodeServersService.checkOpenCodeServer(server) }
                                .buttonStyle(.link)
                            Button("Remove", role: .destructive) {
                                model.openCodeServersService.removeOpenCodeServer(server.id)
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)

                        if case let .failed(message) = model.openCodeServersService.openCodeServerStates[server.id] {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            AddOpenCodeServerForm(model: model)

            Text("Local servers are read on 127.0.0.1. Remote servers are read on the remote machine through its AgentHearth SSH collector, so no OpenCode port is exposed to the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func serverStateLabel(_ serverID: String) -> String {
        switch model.openCodeServersService.openCodeServerStates[serverID] ?? .unknown {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case let .ready(sessionCount): "Connected · \(sessionCount)"
        case .failed: "Unavailable"
        }
    }

    private func serverStateColor(_ serverID: String) -> Color {
        switch model.openCodeServersService.openCodeServerStates[serverID] ?? .unknown {
        case .ready: .green
        case .failed: .red
        case .unknown, .checking: .secondary
        }
    }
}

/// The add-an-SSH-host form. Field contents and the validation message are
/// local view state; only the validated add operation reaches the model.
private struct AddRemoteHostForm: View {
    let model: AppModel
    @State private var name = ""
    @State private var sshDestination = ""
    @State private var message: String?

    var body: some View {
        Group {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Display name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Example: RTX 5090", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("SSH destination")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Example: rtx-server or user@host", text: $sshDestination)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Uses your existing SSH configuration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add SSH Host") {
                            message = model.remoteHostsService.addRemoteHost(name: name, sshDestination: sshDestination)
                            if message == nil {
                                name = ""
                                sshDestination = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sshDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } label: {
                Label("Add an SSH host", systemImage: "plus.circle")
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// The add-a-loopback-server form. Field contents and the validation message
/// are local view state; only the validated add operation reaches the model.
private struct AddOpenCodeServerForm: View {
    let model: AppModel
    @State private var name = ""
    @State private var hostID = AgentHost.local.id
    @State private var port = "4096"
    @State private var message: String?

    var body: some View {
        Group {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Display name")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("Example: Main OpenCode", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Machine")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Picker("Machine", selection: $hostID) {
                                Label("This Mac", systemImage: "laptopcomputer")
                                    .tag(AgentHost.local.id)
                                ForEach(model.remoteHostsService.remoteHosts.filter(\.isEnabled)) { host in
                                    Label(host.displayName, systemImage: "network")
                                        .tag(host.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Loopback port")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("Example: 4096", text: $port)
                                .font(.body.monospaced())
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                        }

                        Spacer()

                        Button("Add Server") {
                            message = model.openCodeServersService.addOpenCodeServer(name: name, hostID: hostID, port: port)
                            if message == nil {
                                name = ""
                                port = "4096"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } label: {
                Label("Add a loopback server", systemImage: "plus.circle")
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
