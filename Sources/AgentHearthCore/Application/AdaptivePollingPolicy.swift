import AgentHearthDomain
import Foundation

public struct AdaptivePollingPolicy: Sendable {
    public init() {}

    public func interval(for snapshots: [ProviderSnapshot]) -> TimeInterval {
        let sessions = snapshots.flatMap(\.sessions)
        // Hook events trigger their own refresh, so a working session's
        // status changes show up at once; this poll only keeps its transcript
        // figures and hookless sessions current. Attention polls faster
        // because no hook reports a prompt being answered.
        if sessions.contains(where: { $0.status == .working }) { return 30 }
        if sessions.contains(where: { $0.status.requiresAttention }) { return 10 }
        if sessions.isEmpty { return 30 }
        return 20
    }
}
