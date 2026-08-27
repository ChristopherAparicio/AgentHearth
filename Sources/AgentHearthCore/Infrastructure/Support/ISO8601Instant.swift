import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// Shared ISO-8601 instant parsing for provider journals and API responses.
///
/// `ISO8601DateFormatter` is thread-safe, so both variants are created once;
/// per-call allocation showed up in transcript-parsing hot loops.
public enum ISO8601Instant {
    // ISO8601DateFormatter is documented thread-safe; it just predates Sendable.
    private nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses an ISO-8601 instant with or without fractional seconds.
    public static func parse(_ value: String) -> Date? {
        withFractionalSeconds.date(from: value) ?? plain.date(from: value)
    }
}

public extension Date {
    /// Converts the millisecond epoch timestamps used across provider wire
    /// formats and hook payloads.
    init(millisecondsSince1970 value: some BinaryInteger) {
        self.init(timeIntervalSince1970: Double(value) / 1_000)
    }
}
