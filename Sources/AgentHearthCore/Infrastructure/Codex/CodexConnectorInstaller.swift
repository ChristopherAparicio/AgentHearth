import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct CodexConnectorInstaller {
    public static let eventNames = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PermissionRequest",
        "Stop",
    ]

    private static let blockStart = "# BEGIN AgentHearth managed hooks"
    private static let blockEnd = "# END AgentHearth managed hooks"

    public let configURL: URL
    public let hookScriptURL: URL

    public init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/config.toml"),
        hookScriptURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/agenthearth/codex-hook.py")
    ) {
        self.configURL = configURL
        self.hookScriptURL = hookScriptURL
    }

    public func state(comparedWith sourceURL: URL?) -> ConnectorInstallationState {
        guard let config = try? String(contentsOf: configURL, encoding: .utf8),
              config.contains(Self.blockStart),
              config.contains(Self.blockEnd)
        else {
            return .notInstalled
        }
        return ConnectorArtifactComparator.state(
            installedAt: hookScriptURL,
            bundledAt: sourceURL,
            missingBundleReason: "Bundled Codex hook is missing",
            whenUnreadable: .updateAvailable
        )
    }

    public func install(from sourceURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: hookScriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: sourceURL).write(to: hookScriptURL, options: .atomic)

        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let base = removingManagedBlock(from: existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = base.isEmpty ? "" : "\n\n"
        let updated = base + separator + managedBlock + "\n"

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(updated.utf8).write(to: configURL, options: .atomic)
    }

    private var managedBlock: String {
        let command = "/usr/bin/python3 \(Shell.quoted(hookScriptURL.path))"
        let entries = Self.eventNames.map { event in
            """
            [[hooks.\(event)]]

            [[hooks.\(event).hooks]]
            type = "command"
            command = \(tomlQuoted(command))
            timeout = 3
            async = false
            """
        }.joined(separator: "\n\n")
        return """
        \(Self.blockStart)
        \(entries)
        \(Self.blockEnd)
        """
    }

    private func removingManagedBlock(from value: String) -> String {
        guard let start = value.range(of: Self.blockStart),
              let end = value.range(of: Self.blockEnd, range: start.upperBound..<value.endIndex)
        else {
            return value
        }
        var result = value
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result
    }

    /// Escapes a string as a TOML basic string.
    ///
    /// `JSONSerialization` is unusable here: it escapes `/` as `\/`, which is not
    /// a legal TOML escape, and a spec-compliant parser (the Rust `toml` crate
    /// Codex uses) rejects the whole file — silently breaking the user's Codex
    /// config. TOML basic strings only recognise `\b \t \n \f \r \" \\` and
    /// `\uXXXX`, so we emit exactly those.
    private func tomlQuoted(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\u{08}": escaped += "\\b"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\u{0C}": escaped += "\\f"
            case "\r": escaped += "\\r"
            case let other where other.value < 0x20 || other.value == 0x7F:
                escaped += String(format: "\\u%04X", other.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }
}
