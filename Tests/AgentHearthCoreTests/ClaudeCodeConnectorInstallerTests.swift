import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class ClaudeCodeConnectorInstallerTests: XCTestCase {
    func testInstallPreservesExistingHooksAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-Claude-Installer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appending(path: "source.py")
        let settings = root.appending(path: ".claude/settings.json")
        let installed = root.appending(path: ".config/agenthearth/claude-code-hook.py")
        let bridgeConfig = root.appending(path: ".config/agenthearth/claude-code.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("print('hook')".utf8).write(to: source)
        try Data("""
        {"theme":"dark","statusLine":{"type":"command","command":"existing-statusline"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-stop-hook"}]}]}}
        """.utf8).write(to: settings)

        let installer = ClaudeCodeConnectorInstaller(
            settingsURL: settings,
            hookScriptURL: installed,
            bridgeConfigURL: bridgeConfig
        )
        XCTAssertEqual(installer.state(comparedWith: source), .notInstalled)
        try installer.install(from: source)
        try installer.install(from: source)
        XCTAssertEqual(installer.state(comparedWith: source), .installed)

        let data = try Data(contentsOf: settings)
        let rootObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(rootObject["theme"] as? String, "dark")
        let hooks = try XCTUnwrap(rootObject["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("existing-stop-hook"))
        XCTAssertEqual(commands.filter { $0.contains("agenthearth/claude-code-hook.py") }.count, 1)
        let statusLine = try XCTUnwrap(rootObject["statusLine"] as? [String: Any])
        XCTAssertTrue((statusLine["command"] as? String)?.contains("agenthearth/claude-code-hook.py") == true)
        let configData = try Data(contentsOf: bridgeConfig)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        XCTAssertEqual(config["previousStatusLineCommand"] as? String, "existing-statusline")
    }
}
