import Foundation
import XCTest
@testable import AgentHearthInfrastructure

/// Runs real child processes: the parser alone says nothing about whether the
/// call can hang, and a hang here would freeze the account-usage fetch for the
/// life of the app.
final class ClaudeCLIAuthStatusTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentHearth-CLIAuth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fakeCLI(_ body: String) throws -> URL {
        let url = directory.appending(path: "claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A signed-out CLI may well report with a failing status; the JSON is
    /// what carries the verdict.
    func testASignedOutCLIIsReadEvenWhenItExitsWithAnError() async throws {
        let cli = try fakeCLI(#"echo '{"loggedIn": false, "authMethod": "none"}'; exit 1"#)
        let verdict = await ClaudeCLIAuthStatus.isSignedIn(executable: cli)
        XCTAssertEqual(verdict, false)
    }

    func testASignedInCLI() async throws {
        let cli = try fakeCLI(#"echo '{"loggedIn": true, "authMethod": "claude.ai"}'"#)
        let verdict = await ClaudeCLIAuthStatus.isSignedIn(executable: cli)
        XCTAssertEqual(verdict, true)
    }

    /// The one that matters: a CLI that never answers must cost a bounded
    /// wait and an unknown verdict, never a fetch stuck forever.
    func testACLIThatNeverAnswersIsGivenUpOn() async throws {
        let cli = try fakeCLI("sleep 30")
        let started = Date()
        let verdict = await ClaudeCLIAuthStatus.isSignedIn(executable: cli, timeout: 0.5)
        XCTAssertNil(verdict)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testNoCLIMeansNoVerdict() async {
        let verdict = await ClaudeCLIAuthStatus.isSignedIn(executable: nil)
        XCTAssertNil(verdict)
        let missing = await ClaudeCLIAuthStatus.isSignedIn(
            executable: directory.appending(path: "does-not-exist")
        )
        XCTAssertNil(missing)
    }
}
