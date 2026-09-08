import AgentHearthCore
import AppKit
import SwiftUI

/// Presents the consumption window, mirroring `HistoryWindowPresenter`: one
/// retained window, and observer registration tied to the window's lifecycle
/// rather than SwiftUI's `onDisappear`, which is not delivered reliably when a
/// retained window is merely ordered out.
@MainActor
final class ConsumptionWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = ConsumptionWindowPresenter()

    private var window: NSWindow?
    private weak var observingModel: AppModel?

    /// - Parameter providerID: the provider whose usage row was clicked, so the
    ///   window opens already scoped to the window the user was looking at.
    func show(model: AppModel, providerID: AgentProviderID? = nil) {
        let sourceWindow = NSApplication.shared.keyWindow
        if sourceWindow !== window {
            sourceWindow?.orderOut(nil)
        }

        if let providerID {
            model.consumptionProviderFilter = providerID
        }
        if observingModel == nil {
            observingModel = model
            model.beginObservingConsumption()
        } else {
            Task { await model.refreshConsumption() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.present(model: model)
        }
    }

    func windowWillClose(_ notification: Notification) {
        observingModel?.endObservingConsumption()
        observingModel = nil
    }

    private func present(model: AppModel) {
        let consumptionWindow: NSWindow
        if let window {
            consumptionWindow = window
        } else {
            let controller = NSHostingController(rootView: ConsumptionView(model: model))
            let created = NSWindow(contentViewController: controller)
            created.title = "AgentHearth Recent Consumption"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 780, height: 680))
            created.minSize = NSSize(width: 680, height: 540)
            created.isReleasedWhenClosed = false
            created.level = .normal
            created.hidesOnDeactivate = false
            created.collectionBehavior = [.moveToActiveSpace]
            created.center()
            created.delegate = self
            window = created
            consumptionWindow = created
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        consumptionWindow.makeKeyAndOrderFront(nil)
        consumptionWindow.orderFrontRegardless()
    }
}
