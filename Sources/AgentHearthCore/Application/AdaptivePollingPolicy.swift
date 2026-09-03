import AgentHearthDomain
import Foundation

public struct AdaptivePollingPolicy: Sendable {
    public init() {}

    public func interval(for snapshots: [ProviderSnapshot]) -> TimeInterval {
        let sessions = snapshots.flatMap(\.sessions)
        if sessions.contains(where: { $0.status == .working }) { return 5 }
        if sessions.contains(where: { $0.status.requiresAttention }) { return 10 }
        if sessions.isEmpty { return 30 }
        return 20
    }
}
