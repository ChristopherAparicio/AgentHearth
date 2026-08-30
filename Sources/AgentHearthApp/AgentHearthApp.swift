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
            // An explicit image+text pair: MenuBarExtra drops a Label's title,
            // which is why the summary never appeared next to the flame.
            if let title = model.menuBarTitle {
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                    Text(title)
                }
            } else {
                Image(systemName: "flame.fill")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

