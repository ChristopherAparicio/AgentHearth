import AgentHearthCore
import Foundation
import SwiftUI

/// Legacy (pre-layout) menu-bar mode. Kept only to migrate stored
/// preferences into a `MenuBarLayout`; nothing reads it afterwards.
enum MenuBarDisplayMode: String, Codable {
    case sessionCounts
    case usageWindow
    case cacheReuse
    case iconOnly
}

/// Legacy usage-window selection, likewise kept for migration.
struct MenuBarUsageWindowSelection: Codable, Equatable, Hashable, Identifiable {
    var providerID: AgentProviderID
    var windowID: String
    var label: String

    var id: String { "\(providerID.rawValue)|\(windowID)" }
}

extension MenuBarLayout {
    /// Builds the equivalent layout for a legacy mode so an upgrade keeps the
    /// menu bar looking the way the user had configured it.
    static func migrated(
        from mode: MenuBarDisplayMode,
        usageWindow: MenuBarUsageWindowSelection?
    ) -> MenuBarLayout {
        switch mode {
        case .iconOnly:
            return MenuBarLayout(showsFlame: true, items: [])
        case .sessionCounts:
            return MenuBarLayout(showsFlame: true, items: [
                MenuBarItem(metric: .sessionCount(.working)),
                MenuBarItem(metric: .sessionCount(.attention)),
            ])
        case .cacheReuse:
            return MenuBarLayout(showsFlame: true, items: [MenuBarItem(metric: .cacheReuse)])
        case .usageWindow:
            guard let usageWindow else { return MenuBarLayout(showsFlame: true, items: []) }
            return MenuBarLayout(showsFlame: true, items: [
                MenuBarItem(
                    metric: .usageWindow(windowID: usageWindow.windowID),
                    scope: .provider(usageWindow.providerID)
                ),
            ])
        }
    }
}

/// A usage window a menu-bar item can pin, as offered by the Settings picker.
struct MenuBarUsageWindowChoice: Identifiable, Hashable {
    let windowID: String
    let label: String

    var id: String { windowID }
}

extension MenuBarTint {
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .white: "White"
        case .gray: "Gray"
        case .orange: "Orange"
        case .green: "Green"
        case .red: "Red"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .purple: "Purple"
        }
    }

    /// `nil` means "the menu bar's own text color".
    var color: Color? {
        switch self {
        case .automatic: nil
        case .white: .white
        case .gray: .gray
        case .orange: .orange
        case .green: .green
        case .red: .red
        case .blue: .blue
        case .yellow: .yellow
        case .purple: .purple
        }
    }
}

extension MenuBarSessionFilter {
    var label: String {
        switch self {
        case .all: "All sessions"
        case .working: "Working"
        case .attention: "Needing attention"
        }
    }
}

/// The metric families offered by the "Add item" menu. Session-count filters
/// and usage windows are refined by separate pickers on the item row.
enum MenuBarMetricKind: String, CaseIterable, Identifiable {
    case sessionCount
    case usageWindow
    case cacheReuse
    case expiringCaches

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionCount: "Session count"
        case .usageWindow: "Usage window"
        case .cacheReuse: "Cache reuse"
        case .expiringCaches: "Expiring caches"
        }
    }

    var defaultMetric: MenuBarMetric {
        switch self {
        case .sessionCount: .sessionCount(.all)
        case .usageWindow: .usageWindow(windowID: nil)
        case .cacheReuse: .cacheReuse
        case .expiringCaches: .expiringCaches
        }
    }

    init(_ metric: MenuBarMetric) {
        switch metric {
        case .sessionCount: self = .sessionCount
        case .usageWindow: self = .usageWindow
        case .cacheReuse: self = .cacheReuse
        case .expiringCaches: self = .expiringCaches
        }
    }
}

/// The prefix families offered on an item row; the custom text lives in a
/// separate field.
enum MenuBarPrefixKind: String, CaseIterable, Identifiable {
    case none
    case providerSymbol
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .providerSymbol: "Provider icon"
        case .text: "Custom text"
        }
    }

    init(_ prefix: MenuBarPrefix) {
        switch prefix {
        case .none: self = .none
        case .providerSymbol: self = .providerSymbol
        case .text: self = .text
        }
    }
}

extension MenuBarScope {
    var label: String {
        switch self {
        case .allProviders: "All providers"
        case let .provider(providerID): providerID.displayName
        }
    }

    static var allChoices: [MenuBarScope] {
        [.allProviders] + AgentProviderID.allCases.map(MenuBarScope.provider)
    }
}
