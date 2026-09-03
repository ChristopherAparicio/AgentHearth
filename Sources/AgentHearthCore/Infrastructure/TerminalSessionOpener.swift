import AgentHearthApplication
import AgentHearthDomain
import Foundation

public enum SessionOpeningError: LocalizedError {
    case executableNotFound(AgentProviderID)
    case invalidRemoteHost
    case invalidSessionID
    case terminalLaunchFailed(String)
    case applicationLaunchFailed(String)
    case missingWorkingDirectory(AgentProviderID)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(providerID):
            "No CLI executable was found for \(providerID.rawValue)"
        case .invalidRemoteHost:
            "The remote session has no valid SSH destination"
        case .invalidSessionID:
            "The session identifier has an unexpected format and was not opened"
        case let .terminalLaunchFailed(message):
            "Could not open the session in Terminal: \(message)"
        case let .applicationLaunchFailed(message):
            "Could not open the provider app: \(message)"
        case let .missingWorkingDirectory(providerID):
            "\(providerID.rawValue) needs a project folder to open in its app"
        }
    }
}

/// Absolute paths of the system tools this opener shells out to.
enum SystemTool {
    static let open = "/usr/bin/open"
    static let osascript = "/usr/bin/osascript"
    static let ssh = "/usr/bin/ssh"
}

/// Per-provider CLI facts: executable discovery and resume invocations.
enum ProviderCLI {
    private static let homebrewBinDirectory = "/opt/homebrew/bin"
    private static let usrLocalBinDirectory = "/usr/local/bin"

    static func executableName(for providerID: AgentProviderID) -> String {
        switch providerID {
        case .codex: "codex"
        case .claudeCode: "claude"
        case .openCode: "opencode"
        }
    }

    static func resumeArguments(for providerID: AgentProviderID, sessionID: String) -> [String] {
        switch providerID {
        case .codex: ["resume", sessionID]
        case .claudeCode: ["--resume", sessionID]
        case .openCode: ["--session", sessionID]
        }
    }

    static func localExecutableCandidates(
        for providerID: AgentProviderID,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String] {
        let name = executableName(for: providerID)
        let sharedCandidates = [
            "\(homebrewBinDirectory)/\(name)",
            "\(usrLocalBinDirectory)/\(name)",
        ]
        let providerCandidates: [String] = switch providerID {
        case .codex: ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        case .claudeCode: ["\(homeDirectory)/.local/bin/claude"]
        case .openCode: ["\(homeDirectory)/.opencode/bin/opencode"]
        }
        return sharedCandidates + providerCandidates
    }
}

/// Names and URL routes of the provider desktop apps.
enum ProviderDesktopApp {
    static let codexAppName = "ChatGPT"
    static let claudeCodeAppName = "Claude"

    enum ClaudeDesktopRoute {
        static let scheme = "claude"
        static let resumeHost = "resume"
        static let sessionQueryItem = "session"
        static let webHost = "claude.ai"
        static let codePath = "/epitaxy"
        static let localSessionPrefix = "local_"
    }

    enum OpenCodeRoute {
        static let scheme = "opencode"
        static let openProjectHost = "open-project"
        static let directoryQueryItem = "directory"
    }
}

enum ClaudeDesktopSessionIdentifier {
    static func uuid(from sessionID: String) -> UUID? {
        let prefix = ProviderDesktopApp.ClaudeDesktopRoute.localSessionPrefix
        guard sessionID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(sessionID.dropFirst(prefix.count)))
    }
}

struct ClaudeDesktopSessionResolver {
    static let defaultSessionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Claude/claude-code-sessions")

    private static let maximumCandidateCount = 200
    private static let maximumFileSize = 1_048_576

    let sessionsURL: URL
    let fileManager: FileManager

    init(
        sessionsURL: URL = Self.defaultSessionsURL,
        fileManager: FileManager = .default
    ) {
        self.sessionsURL = sessionsURL
        self.fileManager = fileManager
    }

    /// Claude Desktop persists a small metadata file for every Code session.
    /// Resolving it only when the user opens a session keeps polling independent
    /// from Claude's private storage while avoiding a duplicate resume/import.
    func localSessionID(for cliSessionID: String) -> String? {
        guard UUID(uuidString: cliSessionID) != nil,
              let enumerator = fileManager.enumerator(
                  at: sessionsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return nil }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let filename = url.deletingPathExtension().lastPathComponent
            guard ClaudeDesktopSessionIdentifier.uuid(from: filename) != nil,
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0, size <= Self.maximumFileSize
            else { continue }
            candidates.append((url, values.contentModificationDate ?? .distantPast))
        }

        let decoder = JSONDecoder()
        for candidate in candidates
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .prefix(Self.maximumCandidateCount) {
            guard let data = try? Data(contentsOf: candidate.url, options: .mappedIfSafe),
                  let record = try? decoder.decode(ClaudeDesktopSessionReference.self, from: data),
                  record.cliSessionID.caseInsensitiveCompare(cliSessionID) == .orderedSame,
                  ClaudeDesktopSessionIdentifier.uuid(from: record.sessionID) != nil
            else { continue }
            return record.sessionID
        }
        return nil
    }
}

private struct ClaudeDesktopSessionReference: Decodable {
    let sessionID: String
    let cliSessionID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cliSessionID = "cliSessionId"
    }
}

enum ProviderAppSessionURL {
    static func url(
        for target: SessionTarget,
        claudeDesktopSessionID: String? = nil
    ) throws -> URL? {
        guard target.host.kind == .local else { return nil }

        switch target.providerID {
        case .codex:
            // The `codex://threads/` route takes a Codex Desktop thread ID,
            // which is distinct from the public CLI resume ID collected by
            // AgentHearth. Opening the app is supported, but exact routing is
            // not possible without a published ID mapping.
            return nil
        case .claudeCode:
            // Claude Desktop uses `local_<UUID>` for sessions created in its
            // Code interface. This route is the same internal route used by
            // Claude's own idle-notification callback (verified on Claude.app
            // 1.34493.1). Opening it avoids creating or importing a duplicate.
            let routedSessionID = claudeDesktopSessionID ?? target.sessionID
            if let localUUID = ClaudeDesktopSessionIdentifier.uuid(from: routedSessionID) {
                var components = URLComponents()
                components.scheme = ProviderDesktopApp.ClaudeDesktopRoute.scheme
                components.host = ProviderDesktopApp.ClaudeDesktopRoute.webHost
                components.path = "\(ProviderDesktopApp.ClaudeDesktopRoute.codePath)/local_\(localUUID.uuidString.lowercased())"
                return components.url
            }

            // The resume route imports a CLI transcript from ~/.claude/projects
            // into Claude's Code section. Claude rejects anything that is not
            // a strict CLI UUID.
            guard UUID(uuidString: target.sessionID) != nil else { return nil }
            var components = URLComponents()
            components.scheme = ProviderDesktopApp.ClaudeDesktopRoute.scheme
            components.host = ProviderDesktopApp.ClaudeDesktopRoute.resumeHost
            components.queryItems = [
                URLQueryItem(
                    name: ProviderDesktopApp.ClaudeDesktopRoute.sessionQueryItem,
                    value: target.sessionID
                ),
            ]
            return components.url
        case .openCode:
            guard let directory = target.workingDirectory else {
                throw SessionOpeningError.missingWorkingDirectory(.openCode)
            }
            var components = URLComponents()
            components.scheme = ProviderDesktopApp.OpenCodeRoute.scheme
            components.host = ProviderDesktopApp.OpenCodeRoute.openProjectHost
            components.queryItems = [
                URLQueryItem(
                    name: ProviderDesktopApp.OpenCodeRoute.directoryQueryItem,
                    value: directory.path
                ),
            ]
            return components.url
        }
    }
}

public actor TerminalSessionOpener: SessionOpening {
    private static let terminalRunScript = """
    on run argv
        set shellCommand to item 1 of argv
        tell application "Terminal"
            activate
            do script shellCommand
        end tell
    end run
    """

    private static let sshDestinationAllowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._@:%+[]-"))

    private let fileManager: FileManager
    private let claudeDesktopSessionResolver: ClaudeDesktopSessionResolver

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.claudeDesktopSessionResolver = ClaudeDesktopSessionResolver(fileManager: fileManager)
    }

    public func open(_ target: SessionTarget, destination: SessionOpenDestination) async throws {
        if destination == .providerApp, target.host.kind == .local {
            try openInProviderApp(target)
            return
        }

        try openInTerminal(target)
    }

    /// Runs the provider CLI with no arguments in a new Terminal tab. Used to
    /// let Claude Code refresh an expired OAuth token, which it does on launch.
    public func openProviderCLI(_ providerID: AgentProviderID) async throws {
        let executable = try executableURL(for: providerID)
        try launchAppleScript(Self.terminalRunScript, arguments: ["exec \(Shell.quoted(executable.path))"])
    }

    private func openInProviderApp(_ target: SessionTarget) throws {
        let claudeDesktopSessionID = target.providerID == .claudeCode
            ? claudeDesktopSessionResolver.localSessionID(for: target.sessionID)
            : nil
        if let url = try ProviderAppSessionURL.url(
            for: target,
            claudeDesktopSessionID: claudeDesktopSessionID
        ) {
            try launchOpen(arguments: [url.absoluteString])
            return
        }

        switch target.providerID {
        case .codex:
            try launchOpen(arguments: ["-a", ProviderDesktopApp.codexAppName])
        case .claudeCode:
            try launchOpen(arguments: ["-a", ProviderDesktopApp.claudeCodeAppName])
        case .openCode:
            // OpenCode has a URL route above when its project is known.
            throw SessionOpeningError.applicationLaunchFailed("no supported local route")
        }
    }

    private func openInTerminal(_ target: SessionTarget) throws {
        // Session IDs arrive from network hooks and locally-parsed transcripts.
        // Shell metacharacters are already neutralised by `Shell.quoted`, but a
        // value beginning with `-` would still reach the provider CLI as a flag
        // (e.g. `codex resume '--dangerously-bypass-approvals-and-sandbox'`).
        // Provider session IDs are machine-generated tokens, so we require a
        // conservative identifier charset and reject anything else.
        guard Self.isValidSessionID(target.sessionID) else {
            throw SessionOpeningError.invalidSessionID
        }
        let arguments = ProviderCLI.resumeArguments(for: target.providerID, sessionID: target.sessionID)

        let command: String
        switch target.host.kind {
        case .local:
            let executable = try executableURL(for: target.providerID)
            var components: [String] = []
            if let directory = target.workingDirectory {
                components.append("cd \(Shell.quoted(directory.path))")
            }
            let invocation = ([Shell.quoted(executable.path)] + arguments.map(Shell.quoted)).joined(separator: " ")
            components.append("exec \(invocation)")
            command = components.joined(separator: " && ")
        case .ssh:
            guard let destination = target.host.sshDestination,
                  Self.isValidSSHDestination(destination)
            else { throw SessionOpeningError.invalidRemoteHost }
            var remoteComponents: [String] = []
            if let directory = target.workingDirectory {
                remoteComponents.append("cd \(Shell.quoted(directory.path))")
            }
            let executableName = ProviderCLI.executableName(for: target.providerID)
            remoteComponents.append(
                "exec \(([executableName] + arguments.map(Shell.quoted)).joined(separator: " "))"
            )
            let remoteCommand = remoteComponents.joined(separator: " && ")
            command = "\(SystemTool.ssh) -t \(Shell.quoted(destination)) \(Shell.quoted(remoteCommand))"
        }

        try launchAppleScript(Self.terminalRunScript, arguments: [command])
    }

    private func launchOpen(arguments: [String]) throws {
        let message = try runProcess(executablePath: SystemTool.open, arguments: arguments)
        if let message, !message.isEmpty {
            throw SessionOpeningError.applicationLaunchFailed(message)
        }
    }

    private func launchAppleScript(_ source: String, arguments: [String]) throws {
        let message = try runProcess(
            executablePath: SystemTool.osascript,
            arguments: ["-e", source] + arguments
        )
        if let message, !message.isEmpty {
            throw SessionOpeningError.terminalLaunchFailed(message)
        }
    }

    private func runProcess(executablePath: String, arguments: [String]) throws -> String? {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
    }

    private func executableURL(for providerID: AgentProviderID) throws -> URL {
        let candidates = ProviderCLI.localExecutableCandidates(for: providerID)
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw SessionOpeningError.executableNotFound(providerID)
        }
        return URL(fileURLWithPath: path)
    }

    private static func isValidSSHDestination(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy(sshDestinationAllowedCharacters.contains)
    }

    private static let sessionIDAllowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))

    static func isValidSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy(sessionIDAllowedCharacters.contains)
    }
}
