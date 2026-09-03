import AgentHearthApplication
import AgentHearthDomain
import Foundation

public struct ClaudeCodeConnectorInstaller {
    public static let eventNames = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Notification",
        "PermissionRequest",
        "Stop",
        "StopFailure",
    ]

    public let settingsURL: URL
    public let hookScriptURL: URL
    public let bridgeConfigURL: URL

    public init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json"),
        hookScriptURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/agenthearth/claude-code-hook.py"),
        bridgeConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/agenthearth/claude-code.json")
    ) {
        self.settingsURL = settingsURL
        self.hookScriptURL = hookScriptURL
        self.bridgeConfigURL = bridgeConfigURL
    }

    public func state(comparedWith sourceURL: URL?) -> ConnectorInstallationState {
        guard isHookConfigured, isStatusLineConfigured else { return .notInstalled }
        return ConnectorArtifactComparator.state(
            installedAt: hookScriptURL,
            bundledAt: sourceURL,
            missingBundleReason: "Bundled Claude Code hook is missing",
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

        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for key in Array(hooks.keys) {
            guard let matchers = hooks[key] as? [[String: Any]] else { continue }
            let pruned = pruneManagedHooks(from: matchers)
            if pruned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = pruned }
        }

        for event in Self.eventNames {
            var matchers = hooks[event] as? [[String: Any]] ?? []
            matchers.append([
                "hooks": [[
                    "type": "command",
                    "command": hookCommand,
                    "timeout": 3,
                ]],
            ])
            hooks[event] = matchers
        }
        root["hooks"] = hooks

        if let existingStatusLine = root["statusLine"] as? [String: Any],
           let existingCommand = existingStatusLine["command"] as? String,
           existingCommand != hookCommand {
            try writeBridgeConfig(previousStatusLineCommand: existingCommand)
        } else if root["statusLine"] == nil {
            try writeBridgeConfig(previousStatusLineCommand: nil)
        }
        root["statusLine"] = [
            "type": "command",
            "command": hookCommand,
            "refreshInterval": 30,
        ]

        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `settings.json` is the user's file, not ours: keep a copy of the
        // version we are about to rewrite so a bad merge is always recoverable.
        try ConnectorConfigBackup.preserve(settingsURL)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private var isHookConfigured: Bool {
        guard let root = try? readSettings(), let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return Self.eventNames.allSatisfy { event in
            guard let matchers = hooks[event] as? [[String: Any]] else { return false }
            return matchers.contains { matcher in
                guard let entries = matcher["hooks"] as? [[String: Any]] else { return false }
                return entries.contains { ($0["command"] as? String) == hookCommand }
            }
        }
    }

    private var isStatusLineConfigured: Bool {
        guard let root = try? readSettings(),
              let statusLine = root["statusLine"] as? [String: Any]
        else { return false }
        return (statusLine["command"] as? String) == hookCommand
    }

    private var hookCommand: String {
        "/usr/bin/python3 \(Shell.quoted(hookScriptURL.path))"
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private func writeBridgeConfig(previousStatusLineCommand: String?) throws {
        try FileManager.default.createDirectory(
            at: bridgeConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config: [String: Any] = [:]
        if let previousStatusLineCommand {
            config["previousStatusLineCommand"] = previousStatusLineCommand
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: bridgeConfigURL, options: .atomic)
        // The hook executes `previousStatusLineCommand` from this file via a
        // shell. Restrict it to the owner so another local user cannot plant a
        // command that would run in the hook's context.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bridgeConfigURL.path
        )
    }

    private func pruneManagedHooks(from matchers: [[String: Any]]) -> [[String: Any]] {
        matchers.compactMap { matcher in
            guard let entries = matcher["hooks"] as? [[String: Any]] else { return matcher }
            let retained = entries.filter { entry in
                guard let command = entry["command"] as? String else { return true }
                return !command.contains("agenthearth/claude-code-hook.py")
            }
            guard !retained.isEmpty else { return nil }
            var updated = matcher
            updated["hooks"] = retained
            return updated
        }
    }
}
