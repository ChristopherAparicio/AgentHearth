import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct SSHCommandResult: Sendable {
    public let standardOutput: Data
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: Data, standardError: String, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
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

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "Invalid SSH destination. Use an SSH config alias or user@host."
        case let .launchFailed(message):
            "Could not launch SSH: \(message)"
        case let .commandFailed(destination, message):
            "SSH connection to \(destination) failed: \(message)"
        }
    }
}

/// Uses the system OpenSSH client, so keys, ProxyJump, host aliases, and agent
/// forwarding continue to be owned by ~/.ssh/config and the user's keychain.
public actor SystemSSHCommandRunner: SSHCommandRunning {
    public init() {}

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
            standardInput: standardInput
        )
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
    /// SSH path and exercised directly by tests with large outputs.
    static func execute(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?
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

        // Drain both pipes concurrently BEFORE waiting for exit. Reading after
        // waitUntilExit() deadlocks whenever the command writes more than the OS
        // pipe buffer (~64 KB): the child blocks on write() while the parent
        // blocks on wait(). Awaiting the reads also frees the concurrency pool
        // instead of parking a cooperative thread — each read completes at EOF,
        // which the child reaches when it exits.
        async let outputData = readToEnd(outputPipe.fileHandleForReading)
        async let errorData = readToEnd(errorPipe.fileHandleForReading)
        let output = await outputData
        let errorText = String(data: await errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        process.waitUntilExit() // returns immediately: both pipes already hit EOF
        return SSHCommandResult(
            standardOutput: output,
            standardError: errorText,
            exitCode: process.terminationStatus
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
