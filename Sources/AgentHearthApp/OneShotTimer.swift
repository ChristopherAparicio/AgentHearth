import Foundation

/// A cancellable one-shot timer. Scheduling replaces any previously armed
/// timer, and a nil fire date simply disarms it. `SmartSleepControl` uses it
/// for the smart-sleep expiration; any feature needing a single deferred
/// main-actor callback can share it.
@MainActor
final class OneShotTimer {
    private var task: Task<Void, Never>?

    /// Arms the timer to fire once at `fireDate`, replacing any previously
    /// armed one. A nil `fireDate` simply cancels the timer.
    func schedule(at fireDate: Date?, onFire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = nil
        guard let fireDate else { return }

        let delay = max(0, fireDate.timeIntervalSinceNow)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            onFire()
            self.task = nil
        }
    }

    /// The next wall-clock occurrence of `targetTime`'s hour and minute after
    /// `now` — the date companion to arming a timer for a daily target time.
    static func nextOccurrence(of targetTime: Date, after now: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.hour, .minute], from: targetTime)
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents
        ) ?? now.addingTimeInterval(24 * 60 * 60)
    }
}
