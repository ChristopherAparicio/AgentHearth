import AgentHearthApplication
import AgentHearthDomain
import Foundation

@MainActor
public final class ProcessInfoSleepAssertion: SleepAssertionControlling {
    private var activity: NSObjectProtocol?

    public var isActive: Bool { activity != nil }

    public init() {}

    public func acquire(reason: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: reason
        )
    }

    public func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

