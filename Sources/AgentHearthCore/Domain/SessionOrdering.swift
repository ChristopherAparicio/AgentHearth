import Foundation

public extension AgentSession {
    /// Canonical snapshot ordering shared by every connector and the monitor
    /// merge: sessions still working come first, everything else by most
    /// recent activity. Intentionally simpler than `SessionDisplayPolicy`,
    /// whose four-rank ordering drives the attention-oriented UI list.
    static func workingFirstThenRecent(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.status == .working, rhs.status != .working { return true }
        if rhs.status == .working, lhs.status != .working { return false }
        return lhs.lastActivityAt > rhs.lastActivityAt
    }
}

public extension Sequence where Element == AgentSession {
    /// Sorts with `AgentSession.workingFirstThenRecent`.
    func sortedWorkingFirst() -> [AgentSession] {
        sorted(by: AgentSession.workingFirstThenRecent)
    }
}
