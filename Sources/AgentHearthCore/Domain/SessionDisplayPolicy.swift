import Foundation

/// Controls the bounded recent-session list shown in the menu bar.
/// Collection keeps a wider window so changing this preference is immediate.
public enum SessionDisplayWindow: Int, CaseIterable, Codable, Identifiable, Sendable {
    case oneDay = 24
    case threeDays = 72
    case sevenDays = 168

    public var id: Int { rawValue }
    public var duration: TimeInterval { TimeInterval(rawValue * 60 * 60) }

    public var label: String {
        switch self {
        case .oneDay: "Last 24 hours"
        case .threeDays: "Last 3 days"
        case .sevenDays: "Last 7 days"
        }
    }
}

public struct SessionDisplayPolicy: Equatable, Sendable {
    public let window: SessionDisplayWindow
    public let maximumPerProvider: Int
    /// Priority sessions rank above every status group. Matching stays in the
    /// Domain via refs, so no UI closure leaks into this pure policy.
    public let pinned: Set<PrioritySessionRef>

    public init(
        window: SessionDisplayWindow = .oneDay,
        maximumPerProvider: Int = 20,
        pinned: Set<PrioritySessionRef> = []
    ) {
        self.window = window
        self.maximumPerProvider = max(1, maximumPerProvider)
        self.pinned = pinned
    }

    public func sessions(from sessions: [AgentSession], now: Date = .now) -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-window.duration)
        return sessions
            .filter { $0.status == .working || $0.status.requiresAttention || $0.lastActivityAt >= cutoff }
            .sorted { lhs, rhs in
                // Pinned sessions lead; within the pinned and unpinned groups
                // the existing ordering is preserved: status rank first (so
                // colors no longer interleave), then most recent activity.
                let lhsPinned = isPinned(lhs)
                let rhsPinned = isPinned(rhs)
                if lhsPinned != rhsPinned { return lhsPinned }
                let lhsRank = Self.statusRank(lhs.status)
                let rhsRank = Self.statusRank(rhs.status)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            .prefix(maximumPerProvider)
            .map { $0 }
    }

    private func isPinned(_ session: AgentSession) -> Bool {
        pinned.contains { $0.matches(session) }
    }

    /// Working first, then sessions needing attention, then idle, then the
    /// finished ones — keeping same-status (same-color) rows together.
    private static func statusRank(_ status: SessionStatus) -> Int {
        if status == .working { return 0 }
        if status.requiresAttention { return 1 }
        if status == .completed { return 3 }
        return 2
    }
}
