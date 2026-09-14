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

/// How a usage window's reset is shown on the provider card.
enum UsageResetDisplay: String, CaseIterable, Identifiable {
    case countdown
    case dateTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .countdown: "Countdown"
        case .dateTime: "Date and time"
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

/// Shared color scale for how full a usage window is, so the provider card
/// and the consumption view grade the same figure the same way.
enum UsagePresentation {
    static func tint(for fraction: Double, base: Color) -> Color {
        if fraction >= 0.90 { return .red }
        if fraction >= 0.75 { return .orange }
        return base
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

extension AccountUsageRemedy {
    /// One line for the menu-bar card: what is wrong, in the user's terms.
    var summary: String {
        switch self {
        case .signIn: "Reset times need a Claude sign-in"
        case .refreshToken: "Reset times need a Claude token refresh"
        case .allowKeychainAccess: "Reset times need Keychain access"
        }
    }

    /// The button that actually fixes it. Named after the command it runs, so
    /// nobody has to guess whether pressing it will help.
    var actionTitle: String {
        switch self {
        case .signIn: "Run claude auth login"
        case .refreshToken: "Open Claude Code"
        case .allowKeychainAccess: "Ask Again"
        }
    }

    /// The consequence, for the Settings warning line.
    var explanation: String {
        switch self {
        case .signIn: "Reset times stay missing until the CLI is signed in again."
        case .refreshToken: "Reset times stay missing until Claude Code refreshes its token."
        case .allowKeychainAccess: "Reset times stay missing until the Keychain read is allowed."
        }
    }

    /// Why a reset cell has no value while this fault stands. Names the cause
    /// rather than repeating the banner, which is already on screen.
    var missingResetReason: String {
        switch self {
        case .signIn: "Reset times come from Anthropic, and the Claude Code CLI is signed out."
        case .refreshToken: "Reset times come from Anthropic, and the stored Claude token has lapsed."
        case .allowKeychainAccess: "Reset times come from Anthropic, and macOS refused the Keychain read."
        }
    }

    var actionSymbol: String {
        switch self {
        case .signIn, .refreshToken: "terminal"
        case .allowKeychainAccess: "key"
        }
    }

    /// Why that button, spelled out for the tooltip.
    var actionHelp: String {
        switch self {
        case .signIn:
            "Runs `claude auth login` in Terminal. The Claude Code CLI is signed out, "
                + "and signing in to the desktop app does not sign in the CLI."
        case .refreshToken:
            "Runs `claude` in Terminal; Claude Code refreshes its lapsed token on launch, "
                + "then usage is fetched again."
        case .allowKeychainAccess:
            "Asks macOS for the Claude Code credentials item again. Choose Always Allow "
                + "so it is not asked on every launch."
        }
    }
}

/// Labels for the Cache Insights period, in one place so the compact picker
/// and the Settings menu cannot drift apart.
enum HistoryPeriod {
    static func label(_ minutes: Int) -> String {
        switch minutes {
        case 60: "1 h"
        case 1_440: "1 j"
        case 10_080: "7 j"
        default: "30 j"
        }
    }

    static func longLabel(_ minutes: Int) -> String {
        switch minutes {
        case 60: "1 hour"
        case 1_440: "24 hours"
        case 10_080: "7 days"
        default: "30 days"
        }
    }
}
