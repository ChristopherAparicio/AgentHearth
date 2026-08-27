import AppKit
import SwiftUI

/// A retained AppKit window avoids the unreliable `openSettings` environment
/// action when it is triggered from a window-style MenuBarExtra in an LSUIElement app.
@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowPresenter()

    private var window: NSWindow?
    private var windowToRestoreAfterSystemSettings: NSWindow?
    private var restoresAfterSystemSettings = false
    private var workspaceActivationObserver: NSObjectProtocol?

    override init() {
        super.init()
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == Bundle.main.bundleIdentifier
            else { return }
            Task { @MainActor [weak self] in
                self?.restoreSettingsWindowAfterSystemSettings()
            }
        }
    }

    func show(model: AppModel) {
        // A window-style MenuBarExtra lives above normal windows. Dismiss it
        // before presenting Settings or it visually covers the new window.
        let sourceWindow = NSApplication.shared.keyWindow
        if sourceWindow !== window {
            sourceWindow?.orderOut(nil)
        }

        DispatchQueue.main.async { [weak self] in
            self?.present(model: model)
        }
    }

    /// System Settings can make an LSUIElement's settings window disappear
    /// from the window cycle. Keep the current window and bring it back when
    /// the user returns to AgentHearth.
    func preserveCurrentSettingsWindowForSystemSettings() {
        windowToRestoreAfterSystemSettings = NSApplication.shared.keyWindow ?? window
        restoresAfterSystemSettings = windowToRestoreAfterSystemSettings?.isVisible == true
    }

    private func present(model: AppModel) {
        let settingsWindow: NSWindow
        if let window {
            settingsWindow = window
        } else {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.title = "AgentHearth Settings"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 640, height: 780))
            created.minSize = NSSize(width: 600, height: 620)
            created.isReleasedWhenClosed = false
            created.level = .normal
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.moveToActiveSpace]
            created.center()
            created.delegate = self
            window = created
            settingsWindow = created
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
    }

    private func restoreSettingsWindowAfterSystemSettings() {
        guard restoresAfterSystemSettings, let windowToRestoreAfterSystemSettings else { return }
        restoresAfterSystemSettings = false
        windowToRestoreAfterSystemSettings.makeKeyAndOrderFront(nil)
        self.windowToRestoreAfterSystemSettings = nil
    }
}
