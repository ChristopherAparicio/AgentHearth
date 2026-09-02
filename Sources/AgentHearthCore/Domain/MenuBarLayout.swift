import Foundation

/// Which sessions a session-count item counts.
public enum MenuBarSessionFilter: String, Codable, CaseIterable, Sendable {
    case all
    case working
    case attention
}

/// The value one menu-bar item displays.
public enum MenuBarMetric: Codable, Equatable, Hashable, Sendable {
    /// Number of sessions in scope matching the filter.
    case sessionCount(MenuBarSessionFilter)
    /// Utilization of one provider usage window. `windowID` is nil for the
    /// highest utilization across every window in scope.
    case usageWindow(windowID: String?)
    /// Mean cache reuse across the sessions in scope that report one.
    case cacheReuse
    /// Number of caches in scope that expire within the warning lead time.
    case expiringCaches
}

/// Which providers an item looks at.
public enum MenuBarScope: Codable, Equatable, Hashable, Sendable {
    case allProviders
    case provider(AgentProviderID)

    public var providerID: AgentProviderID? {
        if case let .provider(providerID) = self { return providerID }
        return nil
    }
}

/// A fixed palette rather than a free color picker, so every choice stays
/// legible on both the light and the dark menu bar. `automatic` follows the
/// menu bar's own text color.
public enum MenuBarTint: String, Codable, CaseIterable, Sendable {
    case automatic
    case white
    case gray
    case orange
    case green
    case red
    case blue
    case yellow
    case purple
}

/// What precedes an item's value.
public enum MenuBarPrefix: Codable, Equatable, Hashable, Sendable {
    case none
    /// The scoped provider's glyph; nothing when the scope is every provider.
    case providerSymbol
    case text(String)
}

public struct MenuBarItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var metric: MenuBarMetric
    public var scope: MenuBarScope
    public var tint: MenuBarTint
    public var prefix: MenuBarPrefix
    /// Skip the item entirely while its value is zero (or unavailable).
    public var hidesWhenZero: Bool

    public init(
        id: UUID = UUID(),
        metric: MenuBarMetric,
        scope: MenuBarScope = .allProviders,
        tint: MenuBarTint = .automatic,
        prefix: MenuBarPrefix = .none,
        hidesWhenZero: Bool = false
    ) {
        self.id = id
        self.metric = metric
        self.scope = scope
        self.tint = tint
        self.prefix = prefix
        self.hidesWhenZero = hidesWhenZero
    }
}

/// The user's menu-bar composition: an ordered list of items next to an
/// optional flame icon. The default is the icon alone.
public struct MenuBarLayout: Codable, Equatable, Sendable {
    public var showsFlame: Bool
    public var items: [MenuBarItem]

    public init(showsFlame: Bool = true, items: [MenuBarItem] = []) {
        self.showsFlame = showsFlame
        self.items = items
    }

    public static let `default` = MenuBarLayout()

    /// The icon can only be hidden while something else is shown; an empty
    /// status item would be unclickable.
    public var effectiveShowsFlame: Bool {
        showsFlame || items.isEmpty
    }
}

/// One item resolved against the current snapshots, ready to draw.
public struct MenuBarRenderedItem: Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let tint: MenuBarTint
    /// Provider whose glyph precedes the text, when the prefix asks for one.
    public let providerSymbol: AgentProviderID?
    public let prefixText: String?

    public init(
        id: UUID,
        text: String,
        tint: MenuBarTint,
        providerSymbol: AgentProviderID? = nil,
        prefixText: String? = nil
    ) {
        self.id = id
        self.text = text
        self.tint = tint
        self.providerSymbol = providerSymbol
        self.prefixText = prefixText
    }
}

/// Resolves a layout against provider snapshots. Pure and provider-neutral so
/// the composition can be unit-tested without the UI.
public enum MenuBarLayoutRenderer {
    public static func render(
        _ layout: MenuBarLayout,
        snapshots: [ProviderSnapshot],
        cacheWarningSeconds: Int
    ) -> [MenuBarRenderedItem] {
        layout.items.compactMap { item in
            let scoped = snapshots.filter { snapshot in
                switch item.scope {
                case .allProviders: true
                case let .provider(providerID): snapshot.id == providerID
                }
            }
            guard let value = value(of: item.metric, in: scoped, cacheWarningSeconds: cacheWarningSeconds) else {
                return nil
            }
            if item.hidesWhenZero, value.isZero { return nil }
            let providerSymbol: AgentProviderID?
            let prefixText: String?
            switch item.prefix {
            case .none:
                providerSymbol = nil
                prefixText = nil
            case .providerSymbol:
                providerSymbol = item.scope.providerID
                prefixText = nil
            case let .text(text):
                providerSymbol = nil
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                prefixText = trimmed.isEmpty ? nil : trimmed
            }
            return MenuBarRenderedItem(
                id: item.id,
                text: value.text,
                tint: item.tint,
                providerSymbol: providerSymbol,
                prefixText: prefixText
            )
        }
    }

    private struct Value {
        let text: String
        let isZero: Bool
    }

    private static func value(
        of metric: MenuBarMetric,
        in snapshots: [ProviderSnapshot],
        cacheWarningSeconds: Int
    ) -> Value? {
        let sessions = snapshots.flatMap(\.sessions)
        switch metric {
        case let .sessionCount(filter):
            let count = sessions.count { session in
                switch filter {
                case .all: true
                case .working: session.status == .working
                case .attention: session.status.requiresAttention
                }
            }
            return Value(text: "\(count)", isZero: count == 0)

        case let .usageWindow(windowID):
            let windows = snapshots.flatMap(\.usageWindows)
            let fraction: Double?
            if let windowID {
                fraction = windows.first { $0.id == windowID }?.usedFraction
            } else {
                fraction = windows.map(\.usedFraction).max()
            }
            guard let fraction else { return nil }
            let percent = Int((fraction * 100).rounded())
            return Value(text: "\(percent)%", isZero: percent == 0)

        case .cacheReuse:
            let rates = sessions.compactMap { session in
                session.cacheHealth?.tokenReuseRate ?? session.cache.cacheReuseRate
            }
            guard !rates.isEmpty else { return nil }
            let percent = Int((rates.reduce(0, +) / Double(rates.count) * 100).rounded())
            return Value(text: "\(percent)%", isZero: percent == 0)

        case .expiringCaches:
            let count = sessions.count { session in
                guard session.cache.temperature == .warm || session.cache.temperature == .expiring,
                      let remaining = session.cache.remainingSeconds
                else { return false }
                return remaining > 0 && remaining <= cacheWarningSeconds
            }
            return Value(text: "\(count)", isZero: count == 0)
        }
    }
}
