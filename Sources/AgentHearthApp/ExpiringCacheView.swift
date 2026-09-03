import AgentHearthCore
import Foundation
import SwiftUI

struct ExpiringCachePanel: View {
    let items: [ExpiringCacheItem]
    let onOpenSession: (SessionTarget) -> Void
    let cacheAlertDisposition: (AgentSession) -> CacheAlertDisposition?
    let cacheNotificationsEnabled: (AgentSession) -> Bool
    let hasSessionRule: (AgentSession) -> Bool
    let onAcknowledgeCache: (AgentSession) -> Void
    let onIgnoreCache: (AgentSession) -> Void
    let onSetSessionNotificationsEnabled: (Bool, AgentSession) -> Void
    let onClearSessionRule: (AgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("Caches expiring soon", systemImage: "timer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ExpiringCacheList(
                items: Array(items.prefix(4)),
                onOpenSession: onOpenSession,
                cacheAlertDisposition: cacheAlertDisposition,
                cacheNotificationsEnabled: cacheNotificationsEnabled,
                hasSessionRule: hasSessionRule,
                onAcknowledgeCache: onAcknowledgeCache,
                onIgnoreCache: onIgnoreCache,
                onSetSessionNotificationsEnabled: onSetSessionNotificationsEnabled,
                onClearSessionRule: onClearSessionRule
            )

            if items.count > 4 {
                Text("+ \(items.count - 4) more in the current view")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.orange.opacity(0.16), lineWidth: 1)
        }
    }
}

struct ExpiringCacheList: View {
    let items: [ExpiringCacheItem]
    let onOpenSession: (SessionTarget) -> Void
    let cacheAlertDisposition: (AgentSession) -> CacheAlertDisposition?
    let cacheNotificationsEnabled: (AgentSession) -> Bool
    let hasSessionRule: (AgentSession) -> Bool
    let onAcknowledgeCache: (AgentSession) -> Void
    let onIgnoreCache: (AgentSession) -> Void
    let onSetSessionNotificationsEnabled: (Bool, AgentSession) -> Void
    let onClearSessionRule: (AgentSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ExpiringCacheRow(
                    item: item,
                    onOpenSession: onOpenSession,
                    cacheAlertDisposition: cacheAlertDisposition,
                    cacheNotificationsEnabled: cacheNotificationsEnabled,
                    hasSessionRule: hasSessionRule,
                    onAcknowledgeCache: onAcknowledgeCache,
                    onIgnoreCache: onIgnoreCache,
                    onSetSessionNotificationsEnabled: onSetSessionNotificationsEnabled,
                    onClearSessionRule: onClearSessionRule
                )
                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, 30)
                }
            }
        }
    }
}

private struct ExpiringCacheRow: View {
    let item: ExpiringCacheItem
    let onOpenSession: (SessionTarget) -> Void
    let cacheAlertDisposition: (AgentSession) -> CacheAlertDisposition?
    let cacheNotificationsEnabled: (AgentSession) -> Bool
    let hasSessionRule: (AgentSession) -> Bool
    let onAcknowledgeCache: (AgentSession) -> Void
    let onIgnoreCache: (AgentSession) -> Void
    let onSetSessionNotificationsEnabled: (Bool, AgentSession) -> Void
    let onClearSessionRule: (AgentSession) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.session.providerID.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.session.providerID.tint)
                .frame(width: 21, height: 21)
                .background(item.session.providerID.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(item.session.titleWithoutProviderPrefix)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.session.providerID.displayName)
                    Text("·")
                    Image(systemName: item.session.host.kind == .local ? "laptopcomputer" : "network")
                    Text(item.session.host.displayName)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(countdown(at: context.date))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(.orange.opacity(0.12), in: Capsule())
            }

            CacheAlertMenu(
                session: item.session,
                disposition: cacheAlertDisposition(item.session),
                notificationsEnabled: cacheNotificationsEnabled(item.session),
                hasSessionRule: hasSessionRule(item.session),
                onAcknowledge: onAcknowledgeCache,
                onIgnoreCurrentCache: onIgnoreCache,
                onSetSessionNotificationsEnabled: onSetSessionNotificationsEnabled,
                onClearSessionRule: onClearSessionRule
            )

            if let target = item.session.target {
                Button {
                    onOpenSession(target)
                } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary.opacity(0.75), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Resume \(item.session.title)")
            }
        }
        .padding(.vertical, 5)
    }

    private func countdown(at date: Date) -> String {
        let remaining = max(0, Int(ceil(item.expiresAt.timeIntervalSince(date))))
        let minutes = remaining / 60
        let seconds = remaining % 60
        let prefix = item.session.cache.confidence == .exactPolicy ? "" : "~"
        return String(format: "%@%d:%02d", prefix, minutes, seconds)
    }
}

struct CacheAlertMenu: View {
    let session: AgentSession
    /// False when the session has no live cache: the per-cache actions
    /// (acknowledge, ignore) disappear and only the standing per-session
    /// notification switches remain, so future caches can be configured
    /// before re-engaging the session.
    var hasActiveCache: Bool = true
    let disposition: CacheAlertDisposition?
    let notificationsEnabled: Bool
    let hasSessionRule: Bool
    let onAcknowledge: (AgentSession) -> Void
    let onIgnoreCurrentCache: (AgentSession) -> Void
    let onSetSessionNotificationsEnabled: (Bool, AgentSession) -> Void
    let onClearSessionRule: (AgentSession) -> Void

    var body: some View {
        Menu {
            if hasActiveCache {
                Button {
                    onAcknowledge(session)
                } label: {
                    Label(
                        disposition == .acknowledged ? "Warning acknowledged" : "Acknowledge warning",
                        systemImage: "checkmark"
                    )
                }
                .disabled(disposition == .acknowledged)

                Button {
                    onIgnoreCurrentCache(session)
                } label: {
                    Label("Ignore this cache", systemImage: "bell.slash")
                }
                .disabled(disposition == .ignoredForCurrentCache)

                Divider()
            }

            Button {
                onSetSessionNotificationsEnabled(!notificationsEnabled, session)
            } label: {
                Label(
                    notificationsEnabled
                        ? "Disable cache notifications for this session"
                        : "Enable cache notifications for this session",
                    systemImage: notificationsEnabled ? "bell.slash" : "bell"
                )
            }

            if hasSessionRule {
                Button("Use project or provider default") {
                    onClearSessionRule(session)
                }
            }
        } label: {
            Image(systemName: menuSymbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 23, height: 23)
                .background(.quaternary.opacity(0.75), in: Circle())
        }
        .menuStyle(.borderlessButton)
        // Without the indicator the menu is exactly its 23pt circle, so rows
        // with and without an active cache keep their controls column-aligned.
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(menuColor)
        .opacity(hasActiveCache ? 1 : 0.55)
        .help(hasActiveCache ? "Cache notification options" : "Cache notifications for this session")
    }

    private var menuSymbol: String {
        if !notificationsEnabled || (hasActiveCache && disposition == .ignoredForCurrentCache) { return "bell.slash" }
        if hasActiveCache, disposition == .acknowledged { return "checkmark.circle" }
        return "bell"
    }

    private var menuColor: Color {
        menuSymbol == "bell" ? .secondary : .orange
    }
}
