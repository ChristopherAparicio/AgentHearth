import AgentHearthCore
import SwiftUI

extension AgentProviderID {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "sparkles"
        case .openCode: "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .codex: .mint
        case .claudeCode: .orange
        case .openCode: .cyan
        }
    }

    /// Settings label for the provider-app choice in the session-opening picker.
    var appDestinationLabel: String {
        switch self {
        case .codex: "Codex app · opens app"
        case .claudeCode: "Claude app · resume session"
        case .openCode: "OpenCode app · project only"
        }
    }

    /// Tooltip for a session's open control when the provider app handles the
    /// click (Terminal handles it otherwise, including for SSH sessions).
    var providerAppOpenHelp: String {
        switch self {
        case .codex: "Open the Codex app"
        case .claudeCode: "Open the session in Claude"
        case .openCode: "Open the project in OpenCode"
        }
    }
}

enum CacheReuseDisplayMode: String, CaseIterable, Identifiable {
    case sessionGlobal
    case lastTurn
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessionGlobal: "Whole session"
        case .lastTurn: "Last turn"
        case .both: "Both"
        }
    }
}

extension SessionStatus {
    var label: String {
        switch self {
        case .working: "Working"
        case .waitingForInput: "Waiting"
        case .waitingForApproval: "Approval"
        case .idle: "Idle"
        case .stuck: "Stuck"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .working: .green
        case .waitingForInput, .waitingForApproval: .yellow
        case .idle: .secondary
        case .stuck, .failed: .red
        case .completed: .blue
        }
    }
}

extension CacheSnapshot {
    var compactDurationText: String? {
        guard (temperature == .warm || temperature == .expiring), let remainingSeconds else {
            return nil
        }
        let minutes = max(1, Int(ceil(Double(remainingSeconds) / 60)))
        let prefix = confidence == .exactPolicy ? "" : "~"
        return "\(prefix)\(minutes)m"
    }

    var displayText: String {
        switch temperature {
        case .warm, .expiring:
            guard let remainingSeconds else {
                return temperature == .warm ? "Warm" : "Expiring"
            }
            let minutes = max(1, Int(ceil(Double(remainingSeconds) / 60)))
            let prefix = confidence == .exactPolicy ? "" : "~"
            return temperature == .warm ? "Warm · \(prefix)\(minutes)m" : "Expiring · \(prefix)\(minutes)m"
        case .cold:
            return "Cold"
        case .unknown:
            return "Cache unknown"
        }
    }
}

extension CacheHealthBand {
    var tint: Color {
        switch self {
        case .healthy: .green
        case .mixed: .yellow
        case .poor: .red
        case .insufficientData: .secondary
        }
    }
}

extension CacheHealthSnapshot {
    var displayText: String {
        guard band() != .insufficientData, let hitRate else {
            return "Hits learning"
        }
        let percentage = hitRate.formatted(.percent.precision(.fractionLength(0)))
        return "Hits \(hitCount)/\(observedRequestCount) · \(percentage)"
    }
}

/// Shared color scale for cache reuse rates, so every surface (session cards,
/// history dashboard) grades the same rate the same way.
enum CacheReusePresentation {
    static func tint(for rate: Double?) -> Color {
        guard let rate else { return .secondary }
        if rate >= 0.80 { return .green }
        if rate >= 0.50 { return .orange }
        return .red
    }
}

extension AgentSession {
    /// Session title without the provider name the surrounding UI already
    /// states — connector fallback titles are "<Provider> · <directory>", and
    /// repeating the provider inside its own card (or next to its icon) wastes
    /// the row's width.
    var titleWithoutProviderPrefix: String {
        let prefix = "\(providerID.displayName) · "
        guard title.hasPrefix(prefix), title.count > prefix.count else { return title }
        return String(title.dropFirst(prefix.count))
    }
}
