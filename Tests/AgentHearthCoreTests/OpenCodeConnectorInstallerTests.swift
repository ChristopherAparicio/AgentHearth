import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class OpenCodeConnectorInstallerTests: XCTestCase {
    func testInstallCopiesPluginCreatesConfigAndDetectsUpdates() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearthTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let sourceURL = temporaryDirectory.appending(path: "source.ts")
        let pluginURL = temporaryDirectory.appending(path: "plugins/agenthearth.ts")
        let configURL = temporaryDirectory.appending(path: "config/opencode.json")
        try Data("version-one".utf8).write(to: sourceURL)
        let installer = OpenCodeConnectorInstaller(pluginURL: pluginURL, configURL: configURL)

        XCTAssertEqual(installer.state(comparedWith: sourceURL), .notInstalled)
        try installer.install(from: sourceURL)
        XCTAssertEqual(installer.state(comparedWith: sourceURL), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))

        try Data("version-two".utf8).write(to: sourceURL)
        XCTAssertEqual(installer.state(comparedWith: sourceURL), .updateAvailable)
    }
}
