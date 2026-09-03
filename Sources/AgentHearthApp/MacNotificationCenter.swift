import AgentHearthCore
import AppKit
import Foundation
import UserNotifications

enum NotificationAuthorizationState: Equatable {
    case notDetermined
    case allowed
    case quiet
    case denied

    var label: String {
        switch self {
        case .notDetermined: "Permission needed"
        case .allowed: "Allowed"
        case .quiet: "Allowed quietly"
        case .denied: "Blocked in System Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .notDetermined: "bell.badge"
        case .allowed: "checkmark.circle.fill"
        case .quiet: "bell.slash.circle"
        case .denied: "exclamationmark.triangle.fill"
        }
    }
}

struct NotificationPermissionStatus: Equatable {
    let authorization: NotificationAuthorizationState
    let alertsEnabled: Bool
    let badgesEnabled: Bool
    let soundsEnabled: Bool

    var deliveryDescription: String {
        guard authorization == .allowed || authorization == .quiet else {
            return authorization.label
        }
        if !alertsEnabled { return "Banners are disabled in System Settings" }
        return "Banners enabled"
    }
}

enum NotificationDeliveryResult: Equatable {
    case submitted
    case presented
    case blocked(NotificationAuthorizationState)
    case failed(String)

    var label: String {
        switch self {
        case .submitted: "Test accepted by macOS; waiting for presentation"
        case .presented: "Test presented by macOS"
        case let .blocked(state): "Notification not sent: \(state.label)"
        case let .failed(message): "Notification failed: \(message)"
        }
    }
}

@MainActor
final class MacNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    private var hasRequestedAuthorizationFromDelivery = false
    private static let cacheExpiryCategory = "cache-expiry"
    private static let sessionPromoteCategory = "session-promote"
    private static let openSessionAction = "open-session"
    private static let ignoreCurrentCacheAction = "ignore-current-cache"
    private static let promoteSessionAction = "PROMOTE_SESSION"

    private let center = UNUserNotificationCenter.current()
    var onOpenTarget: ((SessionTarget) -> Void)?
    var onIgnoreCurrentCache: ((SessionTarget) -> Void)?
    var onPromoteSession: ((SessionTarget) -> Void)?
    var onWillPresent: ((String) -> Void)?

    override init() {
        super.init()
        center.delegate = self
        let open = UNNotificationAction(
            identifier: Self.openSessionAction,
            title: "Open session",
            options: [.foreground]
        )
        let ignore = UNNotificationAction(
            identifier: Self.ignoreCurrentCacheAction,
            title: "Ignore this cache",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.cacheExpiryCategory,
            actions: [open, ignore],
            intentIdentifiers: [],
            options: []
        )
        // Promotion asks carry a single "Prioritize" button; tapping the
        // notification body keeps the default open-session behavior.
        let promote = UNNotificationAction(
            identifier: Self.promoteSessionAction,
            title: "Prioritize",
            options: []
        )
        let promoteCategory = UNNotificationCategory(
            identifier: Self.sessionPromoteCategory,
            actions: [promote],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category, promoteCategory])
    }

    /// `activating` must be true only for user-initiated requests (the Settings
    /// button): explicit activation matters for LSUIElement menu-bar apps, as
    /// macOS can ignore a permission request made while no app window is
    /// active — but activating from a background path steals the user's focus.
    func requestAuthorization(activating: Bool = true) async -> Bool {
        if activating {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    func authorizationState() async -> NotificationAuthorizationState {
        (await permissionStatus()).authorization
    }

    func permissionStatus() async -> NotificationPermissionStatus {
        let settings = await center.notificationSettings()
        let authorization: NotificationAuthorizationState = switch settings.authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .allowed
        case .provisional, .ephemeral:
            .quiet
        case .denied:
            .denied
        @unknown default:
            .denied
        }
        return NotificationPermissionStatus(
            authorization: authorization,
            alertsEnabled: settings.alertSetting == .enabled,
            badgesEnabled: settings.badgeSetting == .enabled,
            soundsEnabled: settings.soundSetting == .enabled
        )
    }

    func openSystemNotificationSettings() {
        // macOS does not provide a public, app-specific notifications URL.
        // This opens the relevant Notifications pane, where AgentHearth is
        // listed by its bundle name.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    func playSound(named name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// `interactive` marks a delivery the user just asked for (the Settings
    /// test button): it may activate the app to force the permission prompt.
    /// Background deliveries ask the system at most once per launch and never
    /// activate — macOS often ignores that quiet request, which is exactly why
    /// the interactive path must stay able to insist.
    func deliver(
        _ alert: AgentAlert,
        playSound: Bool,
        interactive: Bool = false
    ) async -> NotificationDeliveryResult {
        var status = await permissionStatus()
        if status.authorization == .notDetermined {
            if interactive {
                _ = await requestAuthorization(activating: true)
            } else if !hasRequestedAuthorizationFromDelivery {
                hasRequestedAuthorizationFromDelivery = true
                _ = await requestAuthorization(activating: false)
            }
            status = await permissionStatus()
        }
        guard status.authorization == .allowed || status.authorization == .quiet else {
            return .blocked(status.authorization)
        }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.summary
        content.sound = playSound ? .default : nil
        if alert.type == "cache.expiring" {
            content.categoryIdentifier = Self.cacheExpiryCategory
        }
        if alert.type == "session.promote" {
            content.categoryIdentifier = Self.sessionPromoteCategory
        }
        if let target = alert.sessionTarget {
            content.userInfo = [
                "providerID": target.providerID.rawValue,
                "sessionID": target.sessionID,
                "workingDirectory": target.workingDirectory?.path ?? "",
                "hostID": target.host.id,
                "hostName": target.host.displayName,
                "hostKind": target.host.kind.rawValue,
                "sshDestination": target.host.sshDestination ?? "",
            ]
        }
        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        do {
            try await center.add(request)
            return .submitted
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        await MainActor.run { [weak self] in
            self?.onWillPresent?(identifier)
        }
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        return options
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let target = sessionTarget(from: response.notification.request.content.userInfo) else { return }
        let actionIdentifier = response.actionIdentifier
        await MainActor.run { [weak self] in
            if actionIdentifier == Self.ignoreCurrentCacheAction {
                self?.onIgnoreCurrentCache?(target)
            } else if actionIdentifier == Self.promoteSessionAction {
                self?.onPromoteSession?(target)
            } else {
                self?.onOpenTarget?(target)
            }
        }
    }

    private nonisolated func sessionTarget(from info: [AnyHashable: Any]) -> SessionTarget? {
        guard let providerRawValue = info["providerID"] as? String,
              let providerID = AgentProviderID(rawValue: providerRawValue),
              let sessionID = info["sessionID"] as? String
        else { return nil }
        let directoryPath = info["workingDirectory"] as? String
        let hostID = info["hostID"] as? String ?? AgentHost.local.id
        let hostName = info["hostName"] as? String ?? AgentHost.local.displayName
        let hostKind = (info["hostKind"] as? String).flatMap(AgentHostKind.init(rawValue:)) ?? .local
        let destination = info["sshDestination"] as? String
        let host = AgentHost(
            id: hostID,
            displayName: hostName,
            kind: hostKind,
            sshDestination: destination.flatMap { $0.isEmpty ? nil : $0 }
        )
        return SessionTarget(
            providerID: providerID,
            sessionID: sessionID,
            workingDirectory: directoryPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
            host: host
        )
    }
}
