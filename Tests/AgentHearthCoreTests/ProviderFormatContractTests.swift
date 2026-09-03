import Foundation
import Security
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

/// Contract tests against the provider data that exists on *this* machine.
///
/// The connectors read undocumented formats — Claude's transcripts and usage
/// journal, Codex's rollouts, Claude's Keychain profiles — that providers
/// reshape without notice. Every wrong figure this app has shown came from such
/// a drift rather than from broken logic, and unit tests over fixtures cannot
/// see it: the fixture keeps matching the old shape forever.
///
/// So instead of re-describing each format, these tests replay the real
/// parsers over the real files and assert that data still comes out. When a
/// provider moves a field, the failure names the source that stopped parsing.
///
/// Two rules keep them safe and CI-friendly:
/// - a source that is absent **skips** rather than fails, so a machine without
///   that provider (or a CI runner without any) stays green;
/// - nothing secret is read and no user content is asserted or printed — only
///   whether parsing still yields values.
final class ProviderFormatContractTests: XCTestCase {
    // MARK: Claude Code

    func testClaudeKeychainStillExposesACredentialProfile() throws {
        // Attributes only, never `kSecReturnData`: enumerating does not raise
        // the consent dialog, so this stays runnable in an automated suite.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { throw XCTSkip("No readable generic passwords on this machine") }

        let services = items.compactMap { $0[kSecAttrService as String] as? String }
        guard services.contains(where: { $0.hasPrefix(ClaudeAccountUsageFetcher.keychainServicePrefix) })
        else {
            throw XCTSkip("Claude is not signed in on this machine")
        }
        // Reaching here is the contract: at least one item still carries the
        // prefix the fetcher scans for. Claude Code 2.1 moved the token into
        // numbered profiles and blanked the bare item; an exact-name lookup
        // silently found nothing, which is the drift this guards against.
    }

    func testClaudeUsageJournalStillYieldsUtilizationPercentages() throws {
        let journal = try requireSource(
            at: PlanUsageHistoryReader.defaultURL,
            named: "Claude Desktop's usage journal"
        )

        let sample = PlanUsageHistoryReader.latestSample(at: journal)

        let parsed = try XCTUnwrap(
            sample,
            "\(Self.driftPrefix) Claude Desktop's usage journal no longer yields a sample. "
                + "PlanUsageHistoryReader expects `{samples: [{t, u: {fh, sd}}]}`."
        )
        XCTAssertTrue(
            parsed.fiveHourFraction != nil || parsed.sevenDayFraction != nil,
            "\(Self.driftPrefix) the newest journal sample carries neither `u.fh` nor `u.sd`."
        )
    }

    func testClaudeTranscriptsStillYieldSessionsWithTokenCounters() async throws {
        let projects = try requireSource(
            at: ClaudeCodeConnector.defaultProjectsURL,
            named: "Claude Code's transcript directory"
        )

        let connector = ClaudeCodeConnector(projectsURL: projects)
        await connector.setSourceMode(.localOnly)
        let snapshot = try await connector.snapshot()

        guard !snapshot.sessions.isEmpty else {
            throw XCTSkip("No Claude Code session recent enough to check")
        }
        XCTAssertTrue(
            snapshot.sessions.contains { $0.cache.cachedReadTokens != nil || $0.cache.inputTokens != nil },
            "\(Self.driftPrefix) Claude transcripts parse into sessions but no token counters survive. "
                + "The reader expects `message.usage.{input_tokens, cache_read_input_tokens}`."
        )
    }

    // MARK: Codex

    func testCodexRolloutsStillYieldSessionsWithTokenCounters() async throws {
        let sessions = try requireSource(
            at: CodexConnector.defaultSessionsURL,
            named: "Codex's rollout directory"
        )

        let connector = CodexConnector(sessionsURL: sessions)
        await connector.setSourceMode(.localOnly)
        let snapshot = try await connector.snapshot()

        guard !snapshot.sessions.isEmpty else {
            throw XCTSkip("No Codex session recent enough to check")
        }
        XCTAssertTrue(
            snapshot.sessions.contains { $0.cache.cachedReadTokens != nil || $0.cache.inputTokens != nil },
            "\(Self.driftPrefix) Codex rollouts parse into sessions but no token counters survive. "
                + "The reader expects `token_count` events carrying `info.last_token_usage`."
        )
    }

    func testCodexRolloutsStillYieldQuotaWindowsWhenReported() async throws {
        let sessions = try requireSource(
            at: CodexConnector.defaultSessionsURL,
            named: "Codex's rollout directory"
        )

        let connector = CodexConnector(sessionsURL: sessions)
        await connector.setSourceMode(.localOnly)
        let snapshot = try await connector.snapshot()

        // Quotas ride along `token_count` events and are absent from a rollout
        // that never saw one, and every window may legitimately have reset —
        // so nothing here is asserted unless a window actually came through.
        guard let window = snapshot.usageWindows.first else {
            throw XCTSkip("No unexpired Codex quota window reported locally")
        }
        XCTAssertTrue(
            (0...1).contains(window.usedFraction),
            "\(Self.driftPrefix) a Codex quota window reports \(window.usedFraction) outside 0...1. "
                + "The reader expects `rate_limits.{primary,secondary}.used_percent` as a percentage."
        )
        XCTAssertFalse(
            window.label.isEmpty,
            "\(Self.driftPrefix) a Codex quota window has no label. "
                + "The reader derives it from `window_minutes`."
        )
    }

    // MARK: Helpers

    /// Marks a failure as a provider-format drift rather than a logic bug, so a
    /// red suite points at the right thing straight away.
    private static let driftPrefix = "PROVIDER FORMAT DRIFT:"

    /// Skips instead of failing when the machine simply does not have this
    /// provider's data — the normal case in CI and on a fresh checkout.
    private func requireSource(at url: URL, named description: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(description) is not present on this machine")
        }
        return url
    }
}
