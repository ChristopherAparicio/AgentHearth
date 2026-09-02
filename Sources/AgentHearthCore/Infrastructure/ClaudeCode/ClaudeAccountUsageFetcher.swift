import AgentHearthApplication
import AgentHearthDomain
import Foundation
import Security

/// Fetches authoritative 5h/7d usage (with reset timestamps) from Anthropic's
/// account endpoint, reusing the OAuth token Claude Code already stores in
/// the Keychain. Read-only and best-effort: it never writes the Keychain and
/// skips the call when the token is missing or expired, leaving Claude Code
/// to refresh it through normal use.
public struct ClaudeAccountUsageFetcher: Sendable {
    /// Claude Code stores its sign-in as generic passwords whose service is
    /// this prefix, either bare (older versions) or suffixed with a numeric
    /// profile id (`Claude Code-credentials-00000000000002`, Claude Code 2.1+,
    /// which also blanks the bare item). Every item with the prefix is a
    /// candidate; the freshest usable token wins.
    static let keychainServicePrefix = "Claude Code-credentials"
    /// Claude Code's fallback store when the Keychain is unavailable.
    static let fallbackCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/.credentials.json")
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

    struct Credentials: Sendable, Equatable {
        let accessToken: String
        let expiresAt: Date?
    }

    /// Parses one credential store (Keychain item or fallback file). Returns
    /// nil when there is no usable access token — Claude Code 2.1 leaves the
    /// bare Keychain item in place with empty token strings.
    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // expiresAt is epoch milliseconds when present; 0 means "none".
        let expiresAt = (oauth["expiresAt"] as? Double)
            .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000) : nil }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }

    /// Among several stores, prefers a token that is not yet expired, then the
    /// one expiring last (the most recently refreshed sign-in).
    static func selectFreshest(_ candidates: [Credentials], now: Date) -> Credentials? {
        let ranked = candidates.sorted { lhs, rhs in
            let lhsValid = lhs.expiresAt.map { $0 > now } ?? true
            let rhsValid = rhs.expiresAt.map { $0 > now } ?? true
            if lhsValid != rhsValid { return lhsValid }
            return (lhs.expiresAt ?? .distantFuture) > (rhs.expiresAt ?? .distantFuture)
        }
        return ranked.first
    }

    private func readCredentials() -> Credentials? {
        let current = now()
        // Attributes only first (never prompts): find every Claude Code
        // credential item, newest modification first, then read the data of as
        // few as possible — each data read may raise the consent dialog.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        var candidates: [(service: String, modifiedAt: Date)] = []
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                guard let service = item[kSecAttrService as String] as? String,
                      service.hasPrefix(Self.keychainServicePrefix)
                else { continue }
                let modifiedAt = item[kSecAttrModificationDate as String] as? Date ?? .distantPast
                candidates.append((service, modifiedAt))
            }
        }
        candidates.sort { $0.modifiedAt > $1.modifiedAt }

        var parsed: [Credentials] = []
        for candidate in candidates {
            guard let credentials = readKeychainItem(service: candidate.service).flatMap(Self.parseCredentials)
            else { continue }
            parsed.append(credentials)
            // The newest item with a still-valid token is the answer; older
            // items are only opened when the newer ones are unusable.
            if credentials.expiresAt.map({ $0 > current }) ?? true { break }
        }
        if let fromKeychain = Self.selectFreshest(parsed, now: current) { return fromKeychain }

        if let data = try? Data(contentsOf: Self.fallbackCredentialsURL),
           let fallback = Self.parseCredentials(data) {
            return fallback
        }
        return nil
    }

    private func readKeychainItem(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
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
