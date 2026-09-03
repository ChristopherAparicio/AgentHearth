import AgentHearthCore
import AppKit
import SwiftUI

struct MenuBarRootView: View {
    @Bindable var model: AppModel
    @State var sessionFilter: SessionMetricFilter?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.hostScopedSnapshots.count > 1 {
                providerPicker
                    .padding(.top, 14)
            }

            if model.isOpenCodeView, !model.availableOpenCodeServers.isEmpty {
                openCodeServerPicker
                    .padding(.top, model.hostScopedSnapshots.count > 1 ? 9 : 14)
            }

            filtersRow
                .padding(.top, model.hostScopedSnapshots.count > 1 || model.isOpenCodeView ? 9 : 14)

            summary
                .padding(.vertical, 12)

            Divider()

            providerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let sessionOpeningError = model.sessionOpeningError {
                errorBanner(sessionOpeningError)
                    .padding(.bottom, 10)
            }

            Divider()
            smartSleepSection
                .padding(.vertical, 12)
            Divider()
            footer
                .padding(.top, 11)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: 460, height: 620)
        .task {
            await model.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.orange, .orange.opacity(0.72)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "flame.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text("AgentHearth")
                    .font(.headline.weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.availableHosts.count > 1 {
                hostMenu
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isRefreshing)
            .help("Refresh")
        }
    }

    private var hostMenu: some View {
        Menu {
            Button {
                model.setHostSelection(.all)
            } label: {
                Label(
                    "All machines (\(model.availableHosts.count))",
                    systemImage: model.hostSelection == .all ? "checkmark" : "rectangle.3.group"
                )
            }

            Divider()

            ForEach(model.availableHosts) { host in
                Button {
                    model.setHostSelection(.host(host.id))
                } label: {
                    Label(
                        host.displayName,
                        systemImage: model.hostSelection == .host(host.id)
                            ? "checkmark"
                            : host.kind == .local ? "laptopcomputer" : "network"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.selectedHost?.kind == .ssh ? "network" : "laptopcomputer.and.iphone")
                Text(model.selectedHost?.displayName ?? "All (\(model.availableHosts.count))")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.quaternary.opacity(0.7), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter sessions by machine")
    }

    private var headerSubtitle: String {
        if workingCount > 0 {
            return workingCount == 1 ? "1 agent is working" : "\(workingCount) agents are working"
        }
        if attentionCount > 0 {
            return "Action required"
        }
        return "All agents are quiet"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let lastRefreshAt = model.lastRefreshAt {
                let hasError = model.connectorServerError != nil
                Label {
                    // Back the color with words/icon so a connector error is not
                    // signalled by red alone.
                    Text(hasError
                        ? "Connector error · \(lastRefreshAt, style: .relative) ago"
                        : "Updated \(lastRefreshAt, style: .relative) ago")
                } icon: {
                    Image(systemName: hasError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(hasError ? Color.red : Color.green)
                }
                .font(.caption2)
                .foregroundStyle(hasError ? Color.red : Color.secondary)
            } else {
                Text("Waiting for first update")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                HistoryWindowPresenter.shared.show(model: model)
            } label: {
                Label("Cache Insights", systemImage: "chart.xyaxis.line")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button {
                SettingsWindowPresenter.shared.show(model: model)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
