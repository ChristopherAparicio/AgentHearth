import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CodexConnectorInstallerTests: XCTestCase {
    func testInstallPreservesConfigAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-Codex-Installer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appending(path: "source.py")
        let config = root.appending(path: ".codex/config.toml")
        let installed = root.appending(path: ".config/agenthearth/codex-hook.py")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("print('hook')".utf8).write(to: source)
        try Data("model = \"gpt-5.6-sol\"\n".utf8).write(to: config)

        let installer = CodexConnectorInstaller(configURL: config, hookScriptURL: installed)
        XCTAssertEqual(installer.state(comparedWith: source), .notInstalled)
        try installer.install(from: source)
        try installer.install(from: source)

        XCTAssertEqual(installer.state(comparedWith: source), .installed)
        let value = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(value.contains("model = \"gpt-5.6-sol\""))
        XCTAssertEqual(value.components(separatedBy: "# BEGIN AgentHearth managed hooks").count - 1, 1)
        for event in CodexConnectorInstaller.eventNames {
            XCTAssertTrue(value.contains("[[hooks.\(event)]]"))
        }
        // Regression: JSONSerialization emitted `\/`, which is not a valid TOML
        // escape and made the whole config unparseable. The hook path must be
        // written verbatim.
        XCTAssertFalse(value.contains("\\/"), "config.toml must not contain invalid TOML escape sequences")
        XCTAssertTrue(value.contains(installed.path), "config.toml must contain the unescaped hook path")

        // The pre-rewrite copy of the user's config is kept next to it.
        let backup = ConnectorConfigBackup.backupURL(for: config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(try String(contentsOf: backup, encoding: .utf8).contains("model = \"gpt-5.6-sol\""))
    }
}
