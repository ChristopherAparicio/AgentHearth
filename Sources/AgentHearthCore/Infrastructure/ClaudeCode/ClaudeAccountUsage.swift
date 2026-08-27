import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// Decodes Anthropic's `/api/oauth/usage` response into the domain
/// ``AccountUsage`` value. `utilization` is a 0–100 percent; `resets_at` is an
/// ISO-8601 instant with fractional seconds.
public enum ClaudeAccountUsageDecoder {
    public static func decode(_ data: Data, fetchedAt: Date) -> AccountUsage? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let five = response.fiveHour.map(makeWindow)
        let seven = response.sevenDay.map(makeWindow)
        guard five != nil || seven != nil else { return nil }
        return AccountUsage(fiveHour: five, sevenDay: seven, fetchedAt: fetchedAt)
    }

    private static func makeWindow(_ raw: RawWindow) -> AccountUsage.Window {
        AccountUsage.Window(
            utilizationFraction: (raw.utilization ?? 0) / 100,
            resetsAt: raw.resetsAt.flatMap(ISO8601Instant.parse)
        )
    }

    private struct Response: Decodable {
        let fiveHour: RawWindow?
        let sevenDay: RawWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}
