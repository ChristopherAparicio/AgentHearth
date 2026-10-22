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
    /// No pipes, on purpose. This first went through
    /// ``SystemSSHCommandRunner/execute``, whose drain still hangs now and then
    /// past its own timeout — CI caught this very check stuck for over two
    /// minutes against a five-second bound. Here a hang would freeze the
    /// account-usage fetch until the app is relaunched, silently. The answer is
    /// a few lines of JSON, so the CLI writes it to a file, the process is
    /// polled without blocking a thread, and the deadline is enforced by this
    /// loop alone: nothing in it can wait past `timeout`.
    static func isSignedIn(
        executable: URL? = defaultExecutable(),
        timeout: TimeInterval = 5
    ) async -> Bool? {
        guard let executable else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "agenthearth-auth-status-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? handle.close()
            return nil
        }
        // The child holds its own descriptor; ours is no longer needed.
        try? handle.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            guard Date() < deadline else {
                process.terminate()
                return nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The exit status is not consulted: a signed-out CLI may report its
        // verdict with a failing status, and the JSON is what carries it.
        return loggedIn(in: (try? Data(contentsOf: output)) ?? Data())
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
