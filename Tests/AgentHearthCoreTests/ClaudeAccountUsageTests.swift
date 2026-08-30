import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class ClaudeAccountUsageTests: XCTestCase {
    // Trimmed to the fields AgentHearth reads, from a real /api/oauth/usage body.
    private let sample = """
    {
      "five_hour": {"utilization": 26.0, "resets_at": "2026-08-24T18:00:00.059021+00:00", "limit_dollars": null},
      "seven_day": {"utilization": 17.0, "resets_at": "2026-08-29T22:00:00.059054+00:00", "limit_dollars": null},
      "seven_day_opus": null,
      "extra_usage": {"is_enabled": false}
    }
    """

    func testDecodesUtilizationAndResetInstants() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_000_000)
        let usage = try XCTUnwrap(ClaudeAccountUsageDecoder.decode(Data(sample.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(usage.fetchedAt, fetchedAt)
        XCTAssertEqual(try XCTUnwrap(usage.fiveHour).utilizationFraction, 0.26, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage.sevenDay).utilizationFraction, 0.17, accuracy: 0.0001)

        let fiveReset = try XCTUnwrap(usage.fiveHour?.resetsAt)
        let expected = ISO8601DateFormatter().date(from: "2026-08-24T18:00:00Z")!
        XCTAssertEqual(fiveReset.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testReturnsNilWhenNoWindowsPresent() {
        let empty = #"{"seven_day_opus": null, "extra_usage": {"is_enabled": false}}"#
        XCTAssertNil(ClaudeAccountUsageDecoder.decode(Data(empty.utf8), fetchedAt: .now))
    }

    func testClampsUtilizationToUnitRange() throws {
        let body = #"{"five_hour": {"utilization": 140.0, "resets_at": null}}"#
        let usage = try XCTUnwrap(ClaudeAccountUsageDecoder.decode(Data(body.utf8), fetchedAt: .now))
        XCTAssertEqual(usage.fiveHour?.utilizationFraction, 1.0)
        XCTAssertNil(usage.fiveHour?.resetsAt)
    }
}
