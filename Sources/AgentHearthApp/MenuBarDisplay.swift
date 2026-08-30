import AgentHearthCore
import Foundation

/// What the menu-bar label shows next to the flame icon.
enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case sessionCounts
    case usageWindow
    case cacheReuse
    case iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionCounts: "Session counts"
        case .usageWindow: "Usage window"
        case .cacheReuse: "Cache reuse"
        case .iconOnly: "Icon only"
        }
    }
}

/// The provider usage window pinned to the menu bar in `.usageWindow` mode.
/// The label is remembered so the Settings picker can still name the choice
/// while the provider is offline and reports no windows.
struct MenuBarUsageWindowSelection: Codable, Equatable, Hashable, Identifiable {
    var providerID: AgentProviderID
    var windowID: String
    var label: String

    var id: String { "\(providerID.rawValue)|\(windowID)" }
}
