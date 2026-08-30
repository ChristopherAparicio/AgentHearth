import AgentHearthCore
import Foundation
import Observation

enum SmartSleepScheduleMode: String, CaseIterable, Codable, Identifiable {
    case unlimited
    case duration
    case targetTime

    var id: Self { self }
}

/// Owns the smart-sleep feature end to end: the schedule preferences, the
/// mode transitions on the underlying `SmartSleepCoordinator`, persistence of
/// the restored state through `PreferencesStore`, and arming the one-shot
/// expiration timer.
@MainActor
@Observable
final class SmartSleepControl {
    private let coordinator: SmartSleepCoordinator
    private let preferences: PreferencesStore
    private let expirationTimer = OneShotTimer()

    /// Wired by the composition root: supplies the current sessions so a mode
    /// change or expiry can immediately reconcile the sleep assertion.
    @ObservationIgnored var sessions: () -> [AgentSession] = { [] }

    var scheduleMode: SmartSleepScheduleMode
    var durationMinutes: Int
    var targetTime: Date

    var mode: SmartSleepMode { coordinator.mode }
    var isHoldingAssertion: Bool { coordinator.isHoldingAssertion }
    var expiresAt: Date? { coordinator.expiresAt }

    /// Restores the persisted smart-sleep state, discarding an expiration that
    /// already lapsed while the app was not running. The expiration timer is
    /// armed separately via `scheduleExpiration()` once the composition root
    /// has wired the `sessions` provider.
    init(
        coordinator: SmartSleepCoordinator,
        preferences: PreferencesStore
    ) {
        self.coordinator = coordinator
        self.preferences = preferences
        self.scheduleMode = preferences.smartSleepScheduleMode
        self.durationMinutes = preferences.smartSleepDurationMinutes
        self.targetTime = preferences.smartSleepTargetTime
        if let mode = preferences.smartSleepMode {
            let expiration = preferences.smartSleepExpiresAt
            if let expiration, expiration <= .now {
                coordinator.setMode(.off)
                preferences.smartSleepMode = .off
                preferences.smartSleepExpiresAt = nil
            } else {
                coordinator.setMode(mode, expiresAt: expiration)
            }
        }
    }

    func setMode(_ mode: SmartSleepMode) {
        let expiration: Date?
        if mode == .off {
            expiration = nil
        } else if coordinator.mode != .off {
            expiration = coordinator.expiresAt
        } else {
            expiration = makeExpiration()
        }
        coordinator.setMode(mode, expiresAt: expiration)
        coordinator.reconcile(sessions: sessions())
        persistState()
        scheduleExpiration()
    }

    func setScheduleMode(_ scheduleMode: SmartSleepScheduleMode) {
        self.scheduleMode = scheduleMode
        updateExpirationIfActive()
        persistState()
        scheduleExpiration()
    }

    func setDurationMinutes(_ minutes: Int) {
        durationMinutes = minutes
        updateExpirationIfActive()
        persistState()
        scheduleExpiration()
    }

    func setTargetTime(_ targetTime: Date) {
        self.targetTime = targetTime
        updateExpirationIfActive()
        persistState()
        scheduleExpiration()
    }

    /// Called after every snapshot refresh. Reconciling can flip the mode off
    /// when the expiration lapsed, in which case the new state is persisted
    /// and the timer disarmed.
    func reconcileAfterRefresh(sessions: [AgentSession]) {
        let modeBeforeReconcile = coordinator.mode
        coordinator.reconcile(sessions: sessions)
        if modeBeforeReconcile != coordinator.mode {
            persistState()
            scheduleExpiration()
        }
    }

    /// Arms (or disarms) the one-shot expiration timer for the current state.
    func scheduleExpiration() {
        expirationTimer.schedule(at: coordinator.expiresAt) { [weak self] in
            guard let self else { return }
            self.coordinator.reconcile(sessions: self.sessions())
            self.persistState()
        }
    }

    private func updateExpirationIfActive() {
        guard coordinator.mode != .off else { return }
        coordinator.setExpiration(makeExpiration())
        coordinator.reconcile(sessions: sessions())
    }

    private func makeExpiration(now: Date = .now) -> Date? {
        switch scheduleMode {
        case .unlimited:
            nil
        case .duration:
            now.addingTimeInterval(TimeInterval(durationMinutes * 60))
        case .targetTime:
            OneShotTimer.nextOccurrence(of: targetTime, after: now)
        }
    }

    private func persistState() {
        preferences.smartSleepMode = coordinator.mode
        preferences.smartSleepScheduleMode = scheduleMode
        preferences.smartSleepDurationMinutes = durationMinutes
        preferences.smartSleepTargetTime = targetTime
        preferences.smartSleepExpiresAt = coordinator.expiresAt
    }
}
