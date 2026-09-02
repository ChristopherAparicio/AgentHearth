import AgentHearthApplication
import AgentHearthDomain
import Foundation
import Security

/// Fetches authoritative 5h/7d usage (with reset timestamps) from Anthropic's
/// account endpoint, reusing the OAuth token Claude Desktop already stores in
/// the Keychain. Read-only and best-effort: it never writes the Keychain and
/// skips the call when the token is missing or expired, leaving Claude Desktop
/// to refresh it through normal use.
public struct ClaudeAccountUsageFetcher: Sendable {
    private static let keychainService = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"

    let now: @Sendable () -> Date
    let session: URLSession
    /// Every Keychain read of another app's item can raise a macOS access
    /// prompt (unless the user chose "Always Allow"). The token is therefore
    /// kept in memory for the life of the process and the Keychain is only
    /// consulted again once the token is known to be expired or rejected —
    /// at most one prompt per launch plus one per token refresh, instead of
    /// one per poll.
    private let credentialCache = CredentialCache()

    public init(now: @escaping @Sendable () -> Date = Date.init, session: URLSession = .shared) {
        self.now = now
        self.session = session
    }

    public func fetch() async -> AccountUsageFetchOutcome {
        let credentials: Credentials
        if let cached = await credentialCache.current, !isExpired(cached) {
            credentials = cached
        } else {
            await credentialCache.clear()
            guard let fresh = readCredentials() else { return .tokenMissing }
            credentials = fresh
            await credentialCache.store(fresh)
        }
        if isExpired(credentials) {
            await credentialCache.clear()
            return .tokenExpired
        }
        let outcome = await fetchUsage(accessToken: credentials.accessToken)
        if case .tokenExpired = outcome {
            // Claude Code rotated the token: re-read the Keychain next time.
            await credentialCache.clear()
        }
        return outcome
    }

    private func isExpired(_ credentials: Credentials) -> Bool {
        credentials.expiresAt.map { $0 <= now() } ?? false
    }

    /// The network half, split out from Keychain reading so tests can exercise
    /// every HTTP outcome. The token is sent only as a Bearer header to the
    /// hardcoded Anthropic endpoint and is never logged.
    public func fetchUsage(accessToken: String) async -> AccountUsageFetchOutcome {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("no response") }
            if http.statusCode == 401 { return .tokenExpired }
            guard http.statusCode == 200 else { return .failed("HTTP \(http.statusCode)") }
            guard let usage = ClaudeAccountUsageDecoder.decode(data, fetchedAt: now()) else {
                return .failed("unrecognized response")
            }
            return .usage(usage)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    fileprivate struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date?
    }

    private func readCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        // expiresAt is epoch milliseconds when present.
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }
}

/// Process-lifetime holder for the last Keychain read (see `fetch()`).
private actor CredentialCache {
    private(set) var current: ClaudeAccountUsageFetcher.Credentials?

    func store(_ credentials: ClaudeAccountUsageFetcher.Credentials) {
        current = credentials
    }

    func clear() {
        current = nil
    }
}
