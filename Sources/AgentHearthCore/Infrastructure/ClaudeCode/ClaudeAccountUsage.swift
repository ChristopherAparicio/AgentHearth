import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// Decodes Anthropic's `/api/oauth/usage` response into the domain
/// ``AccountUsage`` value. `utilization` is a 0–100 percent; `resets_at` is an
/// ISO-8601 instant with fractional seconds. Besides the global 5h/7d windows,
/// the `limits` array carries per-model weekly limits (`weekly_scoped`), which
/// are often the binding constraint and are surfaced as scoped windows.
public enum ClaudeAccountUsageDecoder {
    public static func decode(_ data: Data, fetchedAt: Date) -> AccountUsage? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let five = response.fiveHour.map(makeWindow)
        let seven = response.sevenDay.map(makeWindow)
        guard five != nil || seven != nil else { return nil }
        return AccountUsage(
            fiveHour: five,
            sevenDay: seven,
            scopedWeekly: scopedWeekly(from: response.limits ?? []),
            fetchedAt: fetchedAt
        )
    }

    private static func makeWindow(_ raw: RawWindow) -> AccountUsage.Window {
        AccountUsage.Window(
            utilizationFraction: (raw.utilization ?? 0) / 100,
            resetsAt: raw.resetsAt.flatMap(ISO8601Instant.parse)
        )
    }

    private static func scopedWeekly(from limits: [RawLimit]) -> [AccountUsage.ScopedWindow] {
        var seen: Set<String> = []
        return limits.compactMap { limit in
            guard limit.kind == "weekly_scoped",
                  let percent = limit.percent,
                  let label = limit.scope?.model?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty
            else { return nil }
            let id = label.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return AccountUsage.ScopedWindow(
                id: id,
                label: label,
                window: AccountUsage.Window(
                    utilizationFraction: percent / 100,
                    resetsAt: limit.resetsAt.flatMap(ISO8601Instant.parse)
                ),
                isActive: limit.isActive ?? false
            )
        }
    }

    private struct Response: Decodable {
        let fiveHour: RawWindow?
        let sevenDay: RawWindow?
        let limits: [RawLimit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
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

    /// One entry of `limits`. Only the fields AgentHearth reads are declared;
    /// unknown kinds decode fine and are ignored by `scopedWeekly`.
    private struct RawLimit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }
}
