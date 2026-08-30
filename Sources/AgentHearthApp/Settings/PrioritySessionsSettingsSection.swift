import AgentHearthCore
import SwiftUI

/// The Priority Sessions section: the notification focus mode, the
/// promote-on-new-session ask, and the list of currently pinned sessions.
struct PrioritySessionsSettingsSection: View {
    let model: AppModel

    var body: some View {
        Section("Priority Sessions") {
            Picker("Notification focus", selection: modeBinding) {
                Text("All sessions").tag(NotificationFocusMode.all)
                Text("Priority only").tag(NotificationFocusMode.priorityOnly)
            }
            .pickerStyle(.segmented)

            Text("Priority only limits session notifications (waiting, finished, cache expiry) to pinned sessions. Usage limit alerts are always delivered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Ask to prioritize new sessions", isOn: askBinding)
                .disabled(model.sessionFocus.mode != .priorityOnly)

            Text("When Priority only is active, a notification offers to prioritize each session that starts working, so new work is never silently muted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.sessionFocus.preferences.pinned.isEmpty {
                Label("No priority session. Pin one with the star in the session list.", systemImage: "star")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sessionFocus.preferences.pinned, id: \.self) { ref in
                    pinnedRow(ref)
                }

                Text("Completed and failed sessions are unpinned automatically; pins unseen for 7 days are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // The service exposes explicit setters (its preferences value is
    // private(set)), so the controls bridge through Binding(get:set:).
    private var modeBinding: Binding<NotificationFocusMode> {
        Binding(
            get: { model.sessionFocus.mode },
            set: { model.sessionFocus.setMode($0) }
        )
    }

    private var askBinding: Binding<Bool> {
        Binding(
            get: { model.sessionFocus.askOnNewSession },
            set: { model.sessionFocus.setAskOnNewSession($0) }
        )
    }

    private func pinnedRow(_ ref: PrioritySessionRef) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ref.providerID.symbolName)
                .font(.caption)
                .foregroundStyle(ref.providerID.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: ref))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(for: ref))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                model.sessionFocus.unpin(ref)
            } label: {
                Image(systemName: "star.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from priority sessions")
        }
    }

    // Best-effort display: a live session provides its title and host name;
    // a pinned session that is currently unobserved falls back to its id.
    private func liveSession(for ref: PrioritySessionRef) -> AgentSession? {
        model.snapshots.flatMap(\.sessions).first(where: ref.matches)
    }

    private func title(for ref: PrioritySessionRef) -> String {
        liveSession(for: ref)?.title ?? ref.sessionID
    }

    private func subtitle(for ref: PrioritySessionRef) -> String {
        var parts = [ref.providerID.displayName]
        if let session = liveSession(for: ref) {
            if let projectName = session.projectName { parts.append(projectName) }
            parts.append(session.host.displayName)
        } else {
            parts.append(model.host(for: ref.hostID)?.displayName ?? ref.hostID)
            parts.append("Not currently observed")
        }
        return parts.joined(separator: " · ")
    }
}
