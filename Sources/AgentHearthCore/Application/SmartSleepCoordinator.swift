import AgentHearthDomain
import Foundation

public enum SmartSleepMode: String, CaseIterable, Codable, Sendable {
    case off
    case keepAwake
    case night
}

@MainActor
public protocol SleepAssertionControlling: AnyObject {
    var isActive: Bool { get }
    func acquire(reason: String)
    func release()
}

@MainActor
public final class SmartSleepCoordinator {
    private let assertion: any SleepAssertionControlling

    public private(set) var mode: SmartSleepMode = .off
    public private(set) var expiresAt: Date?
    public var isHoldingAssertion: Bool { assertion.isActive }

    public init(assertion: any SleepAssertionControlling) {
        self.assertion = assertion
    }

    public func setMode(_ mode: SmartSleepMode, expiresAt: Date? = nil) {
        self.mode = mode
        self.expiresAt = mode == .off ? nil : expiresAt
        if mode == .off {
            assertion.release()
        }
    }

    public func setExpiration(_ expiresAt: Date?) {
        self.expiresAt = mode == .off ? nil : expiresAt
    }

    public func reconcile(sessions: [AgentSession], now: Date = .now) {
        if let expiresAt, expiresAt <= now {
            mode = .off
            self.expiresAt = nil
            assertion.release()
            return
        }

        let hasEligibleWork = sessions.contains { $0.status.preventsIdleSystemSleep }
        if mode != .off, hasEligibleWork {
            assertion.acquire(reason: "AgentHearth is keeping active coding-agent work awake")
        } else {
            assertion.release()
        }
    }
}
