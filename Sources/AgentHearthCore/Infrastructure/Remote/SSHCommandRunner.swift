import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct SSHCommandResult: Sendable {
    public let standardOutput: Data
    public let standardError: String
    public let exitCode: Int32
    /// True when the process was terminated by the command timeout rather than
    /// exiting on its own; `exitCode` then reflects the signal, not the command.
    public let timedOut: Bool

    public init(standardOutput: Data, standardError: String, exitCode: Int32, timedOut: Bool = false) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public protocol SSHCommandRunning: Sendable {
    func run(
        destination: String,
        remoteCommand: String,
        standardInput: Data?
    ) async throws -> SSHCommandResult
}

public enum SSHCommandError: LocalizedError {
    case invalidDestination
    case launchFailed(String)
    case commandFailed(destination: String, message: String)
    case timedOut(destination: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "Invalid SSH destination. Use an SSH config alias or user@host."
        case let .launchFailed(message):
            "Could not launch SSH: \(message)"
        case let .commandFailed(destination, message):
            "SSH connection to \(destination) failed: \(message)"
        case let .timedOut(destination, seconds):
            "SSH command on \(destination) did not finish within \(seconds)s"
        }
    }
}

/// Uses the system OpenSSH client, so keys, ProxyJump, host aliases, and agent
/// forwarding continue to be owned by ~/.ssh/config and the user's keychain.
public actor SystemSSHCommandRunner: SSHCommandRunning {
    /// Wall-clock bound on one remote command. `ConnectTimeout` only covers the
    /// TCP/SSH handshake; a host that accepts the connection and then stalls
    /// (suspended VM, wedged filesystem) would otherwise block the whole
    /// refresh cycle indefinitely.
    public static let defaultCommandTimeout: TimeInterval = 30

    private let commandTimeout: TimeInterval

    public init(commandTimeout: TimeInterval = SystemSSHCommandRunner.defaultCommandTimeout) {
        self.commandTimeout = commandTimeout
    }

    public func run(
        destination: String,
        remoteCommand: String,
        standardInput: Data? = nil
    ) async throws -> SSHCommandResult {
        guard Self.isValid(destination) else { throw SSHCommandError.invalidDestination }

        let result = try await Self.execute(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=6",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=1",
                destination,
                remoteCommand,
            ],
            standardInput: standardInput,
            timeout: commandTimeout
        )
        if result.timedOut {
            throw SSHCommandError.timedOut(destination: destination, seconds: Int(commandTimeout))
        }
        guard result.exitCode == 0 else {
            throw SSHCommandError.commandFailed(
                destination: destination,
                message: result.standardError.isEmpty ? "exit code \(result.exitCode)" : result.standardError
            )
        }
        return result
    }

    /// Launches a process with optional stdin and returns its output, exit
    /// status, and whether `timeout` ended it — never later than `timeout`
    /// plus a short grace for the kill to land.
    ///
    /// No pipes, on purpose. The drain this replaced waited for EOF on
    /// stdout/stderr, and EOF only comes once *every* copy of the write end is
    /// closed: a grandchild left behind (ssh's ControlMaster, a backgrounded
    /// job) or any other process that inherited the descriptor kept it open
    /// after the command itself had exited, and the timeout — which only
    /// signals the command — could not end that wait. CI caught it more than
    /// once: `/bin/echo ok` under a five-second bound stuck past two minutes.
    /// Output goes to temporary files instead, so nothing but the child's own
    /// exit is waited on, and the deadline is enforced by the polling loop.
    /// Files also have no buffer to fill, so large outputs cannot deadlock.
    /// `timeout` defaults to the standard bound; there is deliberately no way
    /// to ask for none.
    static func execute(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval = SystemSSHCommandRunner.defaultCommandTimeout
    ) async throws -> SSHCommandResult {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agenthearth-exec-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SSHCommandError.launchFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "stdout")
        let errorURL = directory.appending(path: "stderr")
        let inputURL = directory.appending(path: "stdin")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var handles: [FileHandle] = []
        defer { for handle in handles { try? handle.close() } }
        do {
            try (standardInput ?? Data()).write(to: inputURL)
            for url in [outputURL, errorURL] { try Data().write(to: url) }
            let input = try FileHandle(forReadingFrom: inputURL)
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            handles = [input, output, error]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
        } catch {
            throw SSHCommandError.launchFailed(error.localizedDescription)
        }
        // The child holds its own descriptors; ours are no longer needed.
        for handle in handles { try? handle.close() }
        handles = []

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var killAt: Date?
        while process.isRunning {
            let now = Date()
            // A cancelled caller ends the command too: Task.sleep returns at
            // once when cancelled, so waiting on would only spin.
            if !timedOut, now >= deadline || Task.isCancelled {
                timedOut = true
                process.terminate()
                killAt = now.addingTimeInterval(2)
            } else if let due = killAt, now >= due {
                // SIGTERM was ignored; this one cannot be.
                kill(process.processIdentifier, SIGKILL)
                killAt = nil
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let errorText = String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SSHCommandResult(
            standardOutput: (try? Data(contentsOf: outputURL)) ?? Data(),
            standardError: errorText,
            exitCode: process.terminationStatus,
            // A child that exited on its own a hair before the deadline is not
            // timed out: the kill shows as a signal exit or, for OpenSSH —
            // which traps SIGTERM and exits 255 — as that status.
            timedOut: timedOut
                && (process.terminationReason == .uncaughtSignal || process.terminationStatus == 255)
        )
    }

    public static func isValid(_ destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("-") else { return false }
        return destination.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "._@:%+[]-"))
                .contains($0)
        }
    }
}
