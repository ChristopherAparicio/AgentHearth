import AgentHearthDomain
import Foundation

/// Asks the Claude Code CLI whether it considers itself signed in.
///
/// The credential stores cannot answer that on their own. A lapsed access
/// token sitting next to a refresh token looks recoverable, but the stores do
/// not say whether that refresh token still works — the fallback file does not
/// even record when it expires — and a revoked one looks exactly like a live
/// one. Guessing "recoverable" sent a signed-out user to a button that only
/// relaunches the CLI, which signs nobody back in. The CLI knows, so ask it.
enum ClaudeCLIAuthStatus {
    /// `true`/`false` per `claude auth status`, or nil when the answer cannot
    /// be had: no CLI installed, no reply in time, or output it cannot parse.
    /// Callers fall back to their own reading of the stores on nil.
    ///
    /// Runs through ``SystemSSHCommandRunner/execute`` rather than a bare
    /// `Process`: it drains the pipes off the cooperative pool and kills a
    /// child that outstays its timeout, and a wait that never ends here would
    /// wedge the account-usage fetch for the life of the app.
    static func isSignedIn(
        executable: URL? = defaultExecutable(),
        timeout: TimeInterval = 5
    ) async -> Bool? {
        guard let executable,
              let result = try? await SystemSSHCommandRunner.execute(
                  executableURL: executable,
                  arguments: ["auth", "status"],
                  standardInput: nil,
                  timeout: timeout
              ),
              !result.timedOut
        else { return nil }
        // The exit status is not consulted: a signed-out CLI may report its
        // verdict with a failing status, and the JSON is what carries it.
        return loggedIn(in: result.standardOutput)
    }

    static func defaultExecutable() -> URL? {
        ProviderCLI.localExecutableCandidates(for: .claudeCode)
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    static func loggedIn(in data: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["loggedIn"] as? Bool
    }
}
