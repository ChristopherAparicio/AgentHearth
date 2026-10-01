import AgentHearthDomain
import Foundation

/// Fetches Codex's quota from the endpoint the CLI itself calls, reusing the
/// token Codex leaves in `~/.codex/auth.json`.
///
/// Rollout files cannot stand in for this. Once the weekly quota is spent,
/// Codex falls back to a reserve model and starts writing *the reserve's*
/// window into `rate_limits` — same `limit_id`, 0% used, a reset a week out —
/// so the exhausted limit stops being recorded on disk at all, and the newest
/// reading of the family reads as a quota that just reset. The endpoint keeps
/// the two apart: the binding quota is `rate_limit`, the reserve sits under
/// `additional_rate_limits`, which is deliberately ignored here.
public struct CodexAccountUsageFetcher: Sendable {
    public static let defaultAuthURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".codex/auth.json")

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let authURL: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        authURL: URL = CodexAccountUsageFetcher.defaultAuthURL,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authURL = authURL
        self.session = session
        self.now = now
    }

    /// The account's current quota windows, or nil when the token is missing,
    /// rejected or unreachable — the caller then keeps what the rollouts said.
    /// Read-only and best-effort: nothing is written back to `auth.json`, and
    /// the token travels only as a Bearer header to the hardcoded endpoint.
    public func fetch() async -> [UsageWindow]? {
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
              let access = auth.tokens?.accessToken, !access.isEmpty,
              let accountID = auth.tokens?.accountID, !accountID.isEmpty
        else { return nil }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (body, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self.windows(from: body, measuredAt: now())
    }

    static func windows(from data: Data, measuredAt: Date) -> [UsageWindow]? {
        guard let payload = try? JSONDecoder().decode(WhamUsage.self, from: data),
              let limit = payload.rateLimit
        else { return nil }
        let windows = [limit.primaryWindow, limit.secondaryWindow]
            .compactMap { $0 }
            .compactMap { window -> UsageWindow? in
                guard let usedPercent = window.usedPercent, let seconds = window.limitWindowSeconds
                else { return nil }
                return .codexQuota(
                    minutes: Int(seconds) / 60,
                    usedPercent: usedPercent,
                    resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) },
                    measuredAt: measuredAt
                )
            }
        return windows.isEmpty ? nil : windows.sorted { $0.id < $1.id }
    }

    struct CodexAuth: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
            }
        }
    }

    struct WhamUsage: Decodable {
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case rateLimit = "rate_limit"
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let limitWindowSeconds: Double?
            let resetAt: TimeInterval?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case limitWindowSeconds = "limit_window_seconds"
                case resetAt = "reset_at"
            }
        }
    }
}
