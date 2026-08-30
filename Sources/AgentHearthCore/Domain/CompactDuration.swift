import Foundation

/// Compact, human-readable formatting of a duration or countdown, rendering the
/// two largest non-zero units so limit resets stay short and glanceable:
/// `4d5h`, `2h40m`, `45m`, `<1m`.
///
/// One type abstracts the stringify so every reset/countdown in the UI reads the
/// same way — a five-hour window naturally shows hours/minutes (it is always
/// under a day) while a weekly window shows days/hours.
public struct CompactDuration: Equatable, Sendable {
    public let seconds: Int

    public init(_ interval: TimeInterval) {
        self.seconds = max(0, Int(interval.rounded()))
    }

    /// The two largest non-zero units, e.g. `4d5h`, `2h40m`, `45m`. Anything
    /// under a minute collapses to `<1m`.
    public var text: String {
        guard seconds >= 60 else { return "<1m" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// A countdown from now until `date`, or nil once the date has passed.
    public static func until(_ date: Date, now: Date = .now) -> CompactDuration? {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return CompactDuration(remaining)
    }
}
