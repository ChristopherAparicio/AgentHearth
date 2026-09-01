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

/// Terminates a child process once `timeout` elapses, unless `finish()` is
/// called first. Thread-safe: the timer fires on a global queue while the
/// owner awaits the pipes.
private final class ProcessWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var finished = false
    private var timer: DispatchWorkItem?

    init(process: Process, timeout: TimeInterval?) {
        guard let timeout, timeout > 0 else { return }
        let item = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process else { return }
            lock.lock()
            let shouldTerminate = !finished && process.isRunning
            if shouldTerminate { fired = true }
            lock.unlock()
            if shouldTerminate { process.terminate() }
        }
        timer = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Cancels the pending timer and reports whether the watchdog killed the
    /// process. A child that exited on its own a hair before the timer ran is
    /// not classified as timed out: the kill shows up either as a signal exit
    /// or, for OpenSSH — which traps SIGTERM and exits 255 after logging
    /// "Killed by signal 15." — as that specific status.
    func finish(_ process: Process) -> Bool {
        lock.lock()
        finished = true
        let killed = fired
        lock.unlock()
        timer?.cancel()
        return killed
            && (process.terminationReason == .uncaughtSignal || process.terminationStatus == 255)
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

    /// Launches a process, feeds optional stdin, and drains stdout/stderr
    /// concurrently before awaiting exit — the deadlock-free core shared by the
    /// SSH path and exercised directly by tests with large outputs. When
    /// `timeout` elapses first, the child is terminated and the result is
    /// flagged `timedOut`.
    static func execute(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval? = nil
    ) async throws -> SSHCommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        do {
            try process.run()
        } catch {
            throw SSHCommandError.launchFailed(error.localizedDescription)
        }

        if let standardInput {
            try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
        }
        try? inputPipe.fileHandleForWriting.close()

        let watchdog = ProcessWatchdog(process: process, timeout: timeout)

        // Drain both pipes concurrently BEFORE waiting for exit. Reading after
        // waitUntilExit() deadlocks whenever the command writes more than the OS
        // pipe buffer (~64 KB): the child blocks on write() while the parent
        // blocks on wait(). Awaiting the reads also frees the concurrency pool
        // instead of parking a cooperative thread — each read completes at EOF,
        // which the child reaches when it exits (or is killed by the watchdog).
        async let outputData = readToEnd(outputPipe.fileHandleForReading)
        async let errorData = readToEnd(errorPipe.fileHandleForReading)
        let output = await outputData
        let errorText = String(data: await errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        process.waitUntilExit() // returns immediately: both pipes already hit EOF
        let timedOut = watchdog.finish(process)
        return SSHCommandResult(
            standardOutput: output,
            standardError: errorText,
            exitCode: process.terminationStatus,
            timedOut: timedOut
        )
    }

    /// Reads a handle to EOF on a background queue so the blocking read never
    /// parks a Swift-concurrency cooperative thread.
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
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
