import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class SSHCommandRunnerTests: XCTestCase {
    // The regression this locks in: reading pipes only after waitUntilExit()
    // deadlocks once output exceeds the ~64 KB pipe buffer. 200 KB must return.
    func testLargeStdoutDoesNotDeadlock() async throws {
        let bytes = 200_000
        let result = try await SystemSSHCommandRunner.execute(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes X | head -c \(bytes)"],
            standardInput: nil
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.count, bytes)
    }

    func testCapturesStdinStdoutAndExitCode() async throws {
        let result = try await SystemSSHCommandRunner.execute(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: Data("hello".utf8)
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "hello")
    }

    func testNonZeroExitIsReported() async throws {
        let result = try await SystemSSHCommandRunner.execute(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf oops >&2; exit 3"],
            standardInput: nil
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.standardError, "oops")
    }

    func testRejectsInvalidDestination() async {
        let runner = SystemSSHCommandRunner()
        do {
            _ = try await runner.run(destination: "-oProxyCommand=evil", remoteCommand: "echo hi", standardInput: nil)
            XCTFail("expected invalid destination to throw")
        } catch let error as SSHCommandError {
            XCTAssertEqual(error, .invalidDestination)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

extension SSHCommandError: Equatable {
    public static func == (lhs: SSHCommandError, rhs: SSHCommandError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidDestination, .invalidDestination): true
        case let (.launchFailed(a), .launchFailed(b)): a == b
        case let (.commandFailed(a1, a2), .commandFailed(b1, b2)): a1 == b1 && a2 == b2
        default: false
        }
    }
}
