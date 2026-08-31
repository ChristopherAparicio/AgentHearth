import AgentHearthCore
import Foundation
import Observation

/// Owns the macOS notification-permission surface: the authorization and
/// permission state, the permission refresh/request flows, the System
/// Settings hand-off, and the test-notification round-trip.
@MainActor
@Observable
final class NotificationAdminService {
    private let notificationCenter: MacNotificationCenter

    /// Wired by the composition root: supplies the current notification
    /// policy for the test notification's sound decision.
    @ObservationIgnored var policy: () -> NotificationPolicy = { NotificationPolicy() }
    /// Wired by the composition root: supplies the current smart-sleep mode
    /// so Night mode can silence the test notification's sound.
    @ObservationIgnored var smartSleepMode: () -> SmartSleepMode = { .off }
    /// Wired by the composition root: keeps the Settings window alive across
    /// the System Settings hand-off. Defaults to doing nothing.
    @ObservationIgnored var preserveSettingsWindow: () -> Void = {}

    var authorization: NotificationAuthorizationState = .notDetermined
    var permissionStatus = NotificationPermissionStatus(
        authorization: .notDetermined,
        alertsEnabled: false,
        badgesEnabled: false,
        soundsEnabled: false
    )
    var lastTestResult: NotificationDeliveryResult?
    private var lastTestRequestID: String?

    init(notificationCenter: MacNotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func refreshAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            let status = await notificationCenter.permissionStatus()
            self.authorization = status.authorization
            self.permissionStatus = status
        }
    }

    func requestAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            _ = await notificationCenter.requestAuthorization()
            let status = await notificationCenter.permissionStatus()
            self.authorization = status.authorization
            self.permissionStatus = status
        }
    }

    func openSystemSettings() {
        preserveSettingsWindow()
        notificationCenter.openSystemNotificationSettings()
    }

    func sendTestNotification() {
        Task { [weak self] in
            guard let self else { return }
            let requestID = UUID().uuidString
            self.lastTestRequestID = requestID
            self.lastTestResult = nil
            let result = await notificationCenter.deliver(
                AgentAlert(
                    id: requestID,
                    sourceID: .agentHearth,
                    type: "notification.test",
                    severity: .information,
                    title: "AgentHearth notifications are ready",
                    summary: "This is a test notification from AgentHearth."
                ),
                playSound: policy().shouldPlaySound(
                    for: .information,
                    smartSleepMode: smartSleepMode()
                ),
                interactive: true
            )
            if self.lastTestRequestID == requestID,
               self.lastTestResult != .presented {
                self.lastTestResult = result
            }
            let status = await notificationCenter.permissionStatus()
            self.authorization = status.authorization
            self.permissionStatus = status
        }
    }

    func markNotificationPresented(_ identifier: String) {
        guard identifier == lastTestRequestID else { return }
        lastTestResult = .presented
    }

    func previewSound(named name: String) {
        notificationCenter.playSound(named: name)
    }
}
