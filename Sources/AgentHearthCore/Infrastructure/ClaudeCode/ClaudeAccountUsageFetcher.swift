import AgentHearthApplication
import AgentHearthDomain
import Foundation
import Security

/// Result of opening one credential store.
public enum ClaudeCredentialStoreRead: Sendable {
    case data(Data)
    /// The store is there but macOS declined to hand over its contents — the
    /// consent dialog was refused, or could not be shown. Distinct from
    /// `missing`, which would otherwise be read as "no sign-in exists".
    case denied
    case missing
}

/// The credential-store surface ``ClaudeAccountUsageFetcher`` needs, behind a
/// protocol so the classification it drives can be exercised without a real
/// Keychain — and therefore without the consent dialog that reading one raises.
public protocol ClaudeCredentialStoreReading: Sendable {
    /// Every store holding Claude Code credentials, most recently written
    /// first. Reading attributes never prompts, so the ordering is free.
    func services() -> [String]
    func read(service: String) -> ClaudeCredentialStoreRead
    /// Claude Code's fallback store, used when the Keychain is unavailable.
    func fallbackStore() -> Data?
}

/// The real store: Claude Code's generic-password items plus its JSON fallback.
public struct KeychainClaudeCredentialStore: ClaudeCredentialStoreReading {
    /// Claude Code stores its sign-in as generic passwords whose service is
    /// this prefix, either bare or suffixed with a numeric profile id
    /// (`Claude Code-credentials-00000000000002`). Which one is live varies by
    /// version, so every item with the prefix is a candidate.
    public static let servicePrefix = "Claude Code-credentials"
    public static let fallbackURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/.credentials.json")

    private let servicePrefix: String
    private let fallbackURL: URL

    public init(
        servicePrefix: String = KeychainClaudeCredentialStore.servicePrefix,
        fallbackURL: URL = KeychainClaudeCredentialStore.fallbackURL
    ) {
        self.servicePrefix = servicePrefix
        self.fallbackURL = fallbackURL
    }

    public func services() -> [String] {
        // Attributes only (never prompts): find every candidate and order it,
        // so the data reads that follow — each of which may raise the consent
        // dialog — can stop at the first usable token.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items
            .compactMap { item -> (service: String, modifiedAt: Date)? in
                guard let service = item[kSecAttrService as String] as? String,
                      service.hasPrefix(servicePrefix)
                else { return nil }
                return (service, item[kSecAttrModificationDate as String] as? Date ?? .distantPast)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .map(\.service)
    }

    public func read(service: String) -> ClaudeCredentialStoreRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { return .missing }
            return .data(data)
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired, errSecUserCanceled:
            return .denied
        default:
            return .missing
        }
    }

    public func fallbackStore() -> Data? {
        try? Data(contentsOf: fallbackURL)
    }
}

/// Fetches authoritative 5h/7d usage (with reset timestamps) from Anthropic's
/// account endpoint, reusing the OAuth token Claude Code already stores in
/// the Keychain. Read-only and best-effort: it never writes the Keychain and
/// skips the call whenever no usable token can be read, reporting *why* so the
/// caller can name the one gesture that fixes it.
public struct ClaudeAccountUsageFetcher: Sendable {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"

    let now: @Sendable () -> Date
    let session: URLSession
    let stores: any ClaudeCredentialStoreReading
    /// Every Keychain read of another app's item can raise a macOS access
    /// prompt (unless the user chose "Always Allow"). The token is therefore
    /// kept in memory for the life of the process and the Keychain is only
    /// consulted again once the token is known to be expired or rejected —
    /// at most one prompt per launch plus one per token refresh, instead of
    /// one per poll.
    private let credentialCache = CredentialCache()

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        session: URLSession = .shared,
        stores: any ClaudeCredentialStoreReading = KeychainClaudeCredentialStore()
    ) {
        self.now = now
        self.session = session
        self.stores = stores
    }

    public func fetch() async -> AccountUsageFetchOutcome {
        let credentials: Credentials
        if let cached = await credentialCache.current, !isExpired(cached) {
            credentials = cached
        } else {
            await credentialCache.clear()
            switch readCredentials() {
            case let .found(fresh):
                credentials = fresh
                await credentialCache.store(fresh)
            case .expiredButRefreshable: return .tokenExpired
            case .signedOut: return .signedOut
            case .accessDenied: return .keychainAccessDenied
            }
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
    /// nil when there is no usable access token — Claude Code leaves a record
    /// in place with empty token strings both when it moves a profile to a
    /// suffixed item and when the account is logged out.
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

    /// Whether a store still holds a refresh token that has not lapsed — the
    /// one signal that separates "the CLI can mint a new access token on its
    /// own" from "the account is signed out".
    ///
    /// Read separately from ``parseCredentials`` because a store can carry a
    /// live refresh token while its access token is already blank or lapsed.
    /// A record with no `refreshTokenExpiresAt` counts as *not* refreshable: we
    /// cannot verify such a token, and sending someone to sign in when the CLI
    /// could have refreshed itself merely costs them a login, whereas the
    /// opposite mistake sends them to a button that does nothing at all.
    static func hasLiveRefreshToken(_ data: Data, now: Date) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let milliseconds = oauth["refreshTokenExpiresAt"] as? Double,
              milliseconds > 0
        else { return false }
        return Date(timeIntervalSince1970: milliseconds / 1_000) > now
    }

    /// What a sweep of the credential stores established. The failure cases are
    /// distinguished so callers can name the one gesture that fixes each.
    enum CredentialLookup: Sendable {
        /// A token that is usable right now.
        case found(Credentials)
        /// Every token has lapsed, but a live refresh token survives: running
        /// the CLI once is enough.
        case expiredButRefreshable
        /// Nothing usable and nothing to refresh from — a new sign-in is the
        /// only way back.
        case signedOut
        /// At least one store exists but macOS would not hand over its data.
        case accessDenied
    }

    private func readCredentials() -> CredentialLookup {
        let current = now()
        // Every store we could actually open, kept so a sweep that finds no
        // usable token can still tell "signed out" from "expired but
        // refreshable" — the two call for opposite advice.
        var opened: [Data] = []
        var wasDenied = false

        for service in stores.services() {
            switch stores.read(service: service) {
            case let .data(data):
                opened.append(data)
                // The newest store with a still-valid token is the answer;
                // older ones are only opened when the newer are unusable.
                if let credentials = Self.parseCredentials(data), !isExpired(credentials) {
                    return .found(credentials)
                }
            case .denied:
                wasDenied = true
            case .missing:
                continue
            }
        }

        if let data = stores.fallbackStore() {
            opened.append(data)
            if let fallback = Self.parseCredentials(data), !isExpired(fallback) {
                return .found(fallback)
            }
        }

        // A refused read leaves us genuinely unable to say what is stored, so
        // it outranks the guesses below: telling someone to sign in again when
        // their sign-in is fine is the worse mistake.
        if wasDenied { return .accessDenied }
        if opened.contains(where: { Self.hasLiveRefreshToken($0, now: current) }) {
            return .expiredButRefreshable
        }
        return .signedOut
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
