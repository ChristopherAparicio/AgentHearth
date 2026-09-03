import AgentHearthCore
import SwiftUI

@main
struct AgentHearthApp: App {
    @State private var model = AppModel.live()

    init() {
        // Status dots and row controls rely on hover tooltips; the system's
        // ~1.5s default makes them feel absent. Registered (not set) so it
        // only provides this app's default without persisting an override.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(model: model)
        } label: {
            MenuBarStatusLabel(
                items: model.menuBarRenderedItems,
                showsFlame: model.menuBarLayout.effectiveShowsFlame
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

