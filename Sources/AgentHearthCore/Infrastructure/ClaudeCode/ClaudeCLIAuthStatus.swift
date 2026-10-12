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
    static func isSignedIn(timeout: TimeInterval = 5) -> Bool? {
        guard let executable = ProviderCLI.localExecutableCandidates(for: .claudeCode)
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return loggedIn(in: output.fileHandleForReading.readDataToEndOfFile())
    }

    static func loggedIn(in data: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["loggedIn"] as? Bool
    }
}
