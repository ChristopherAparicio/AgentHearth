import AppKit
import SwiftUI

@MainActor
final class HistoryWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowPresenter()

    private var window: NSWindow?
    /// The model registered as a dashboard observer while the window is open.
    /// Registration is tied to the window's lifecycle rather than SwiftUI's
    /// `onDisappear`, which is not delivered reliably when a retained window
    /// is merely ordered out.
    private weak var observingModel: AppModel?

    func show(model: AppModel) {
        let sourceWindow = NSApplication.shared.keyWindow
        if sourceWindow !== window {
            sourceWindow?.orderOut(nil)
        }

        if observingModel == nil {
            observingModel = model
            model.beginObservingHistoryDashboard()
        } else {
            Task { await model.refreshHistoryDashboard() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.present(model: model)
        }
    }

    func windowWillClose(_ notification: Notification) {
        observingModel?.endObservingHistoryDashboard()
        observingModel = nil
    }

    private func present(model: AppModel) {
        let historyWindow: NSWindow
        if let window {
            historyWindow = window
        } else {
            let controller = NSHostingController(rootView: HistoryDashboardView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.title = "AgentHearth Cache Insights"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 780, height: 680))
            created.minSize = NSSize(width: 680, height: 560)
            created.isReleasedWhenClosed = false
            created.level = .normal
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.moveToActiveSpace]
            created.center()
            created.delegate = self
            window = created
            historyWindow = created
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        historyWindow.makeKeyAndOrderFront(nil)
        historyWindow.orderFrontRegardless()
    }
}
