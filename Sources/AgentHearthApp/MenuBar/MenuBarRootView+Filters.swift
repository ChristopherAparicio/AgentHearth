import AgentHearthCore
import SwiftUI

extension MenuBarRootView {
    @ViewBuilder
    var providerPicker: some View {
        if model.hostScopedSnapshots.count <= 3 {
            Picker("Provider", selection: selectionBinding) {
                Text("Dashboard").tag(ProviderSelection.all)
                ForEach(model.hostScopedSnapshots) { snapshot in
                    Text(snapshot.id.displayName)
                        .tag(ProviderSelection.provider(snapshot.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        } else {
            providerMenu
        }
    }

    private var selectionBinding: Binding<ProviderSelection> {
        Binding(
            get: { model.selection },
            set: { model.setSelection($0) }
        )
    }

    private var providerMenu: some View {
        Menu {
            Button {
                model.setSelection(.all)
            } label: {
                Label(
                    "Dashboard (\(model.hostScopedSnapshots.count) providers)",
                    systemImage: model.selection == .all ? "checkmark" : "rectangle.3.group"
                )
            }

            Divider()

            ForEach(model.hostScopedSnapshots) { snapshot in
                Button {
                    model.setSelection(.provider(snapshot.id))
                } label: {
                    Label(
                        snapshot.id.displayName,
                        systemImage: model.selection == .provider(snapshot.id)
                            ? "checkmark" : snapshot.id.symbolName
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedProviderSymbol)
                    .foregroundStyle(.orange)
                Text(selectedProviderName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .help("Filter sessions by provider")
    }

    private var selectedProviderName: String {
        switch model.selection {
        case .all: "Dashboard (\(model.hostScopedSnapshots.count) providers)"
        case let .provider(providerID): providerID.displayName
        }
    }

    private var selectedProviderSymbol: String {
        switch model.selection {
        case .all: "rectangle.3.group"
        case let .provider(providerID): providerID.symbolName
        }
    }

    // The time-window and status filters share one compact row: the icons and
    // current values are self-explanatory, so the long "Recent sessions" /
    // "Status" labels are dropped to reclaim vertical space above the list.
    var filtersRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Recent sessions", selection: sessionWindowBinding) {
                    ForEach(SessionDisplayWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            .help("Show sessions active during the selected period")

            Spacer(minLength: 8)

            priorityFocusToggle

            Menu {
                Button {
                    model.showAllSessionStatuses()
                } label: {
                    Label(
                        "All statuses",
                        systemImage: model.isFilteringSessionStatuses ? "square.stack.3d.up" : "checkmark"
                    )
                }

                Divider()

                ForEach(SessionStatus.allCases, id: \.self) { status in
                    Button {
                        model.toggleSessionStatusVisibility(status)
                    } label: {
                        Label(
                            status.label,
                            systemImage: model.isSessionStatusVisible(status) ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "circle.grid.2x2")
                        .font(.caption2)
                        .foregroundStyle(model.isFilteringSessionStatuses ? Color.accentColor : Color.secondary)
                    Text(statusFilterSummary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose which session statuses appear in the list")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
    }

    private var sessionWindowBinding: Binding<SessionDisplayWindow> {
        $model.sessionDisplayWindow
    }

    // Toggles the focus between all sessions and pinned ones only — both the
    // list and session notifications follow it. The star badge shows how many
    // sessions are currently pinned. The dropdown half offers bulk pinning:
    // every session whose cache is still warm, or clearing all pins.
    private var priorityFocusToggle: some View {
        let isPriorityOnly = model.sessionFocus.isPriorityOnly
        let pinnedCount = model.scopedPinnedSessionCount
        let warmCount = model.unpinnedWarmCacheSessionCount
        // Inert without a pinned session in this scope — but never disabled
        // while active, so the mode can always be turned back off.
        let isInert = !isPriorityOnly && pinnedCount == 0 && warmCount == 0
        return Menu {
            Button {
                model.pinWarmCacheSessions()
            } label: {
                Label(
                    warmCount == 0
                        ? "Pin all warm-cache sessions"
                        : "Pin all warm-cache sessions (\(warmCount))",
                    systemImage: "flame"
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(warmCount == 0)

            Button {
                model.pinWarmCacheSessions()
                model.sessionFocus.setMode(.priorityOnly)
            } label: {
                Label("Pin warm-cache sessions and focus on them", systemImage: "star.fill")
            }
            .disabled(warmCount == 0 && model.sessionFocus.pinnedCount == 0)

            Divider()

            Button(role: .destructive) {
                model.sessionFocus.unpinAll()
            } label: {
                Label("Unpin all", systemImage: "star.slash")
            }
            .disabled(model.sessionFocus.pinnedCount == 0)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isPriorityOnly ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(isPriorityOnly ? Color.yellow : Color.secondary)
                Text("Priority only")
                    .lineLimit(1)
                if pinnedCount > 0 {
                    Text("\(pinnedCount)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.yellow.opacity(0.18), in: Capsule())
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                isPriorityOnly ? AnyShapeStyle(.yellow.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                in: Capsule()
            )
        } primaryAction: {
            model.sessionFocus.setMode(isPriorityOnly ? .all : .priorityOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(isInert)
        .opacity(isInert ? 0.45 : 1)
        .help(
            isInert
                ? "No priority sessions here — star a session, or pin every warm-cache session from the menu"
                : isPriorityOnly
                    ? "Showing and notifying priority sessions only. Click to include every session; open the menu to pin all warm-cache sessions (⇧⌘P)."
                    : "Show and notify priority sessions only. Open the menu to pin all warm-cache sessions (⇧⌘P)."
        )
    }

    private var statusFilterSummary: String {
        guard model.isFilteringSessionStatuses else { return "All statuses" }
        let visible = model.visibleSessionStatuses
        switch visible.count {
        case 0: return "None"
        case 1: return visible.first?.label ?? "1 selected"
        default: return "\(visible.count) selected"
        }
    }

    var openCodeServerPicker: some View {
        HStack(spacing: 9) {
            Image(systemName: "server.rack")
                .font(.caption)
                .foregroundStyle(.cyan)

            Text("OpenCode source")
                .font(.caption.weight(.medium))

            Spacer()

            Menu {
                Button {
                    model.setOpenCodeServerSelection(.all)
                } label: {
                    Label(
                        "All servers (\(model.availableOpenCodeServers.count))",
                        systemImage: model.openCodeServerSelection == .all
                            ? "checkmark" : "square.stack.3d.up"
                    )
                }

                Divider()

                ForEach(model.availableOpenCodeServers) { server in
                    Button {
                        model.setOpenCodeServerSelection(.server(server.id))
                    } label: {
                        Label(
                            "\(server.displayName) · \(model.host(for: server.hostID)?.displayName ?? "Unknown")",
                            systemImage: model.openCodeServerSelection == .server(server.id)
                                ? "checkmark"
                                : server.hostID == AgentHost.local.id ? "laptopcomputer" : "network"
                        )
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.selectedOpenCodeServer?.displayName ?? "All servers")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(.cyan.opacity(0.10), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }
}
