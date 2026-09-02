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

    /// The `limits` array carries per-model weekly limits; only `weekly_scoped`
    /// entries with a model name become scoped windows, deduplicated by name.
    func testDecodesPerModelWeeklyLimits() throws {
        let body = """
        {
          "five_hour": {"utilization": 25.0, "resets_at": "2026-09-02T18:00:00.263421+00:00"},
          "seven_day": {"utilization": 35.0, "resets_at": "2026-09-05T22:00:00.263440+00:00"},
          "limits": [
            {"kind": "session", "group": "session", "percent": 25, "resets_at": "2026-09-02T18:00:00.263421+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 35, "resets_at": "2026-09-05T22:00:00.263440+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 56, "resets_at": "2026-09-05T22:00:00.263659+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": null, "scope": {"model": {"id": null, "display_name": "Opus 5"}}, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 99, "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 40, "scope": {"surface": "cowork"}},
            {"kind": "mystery_future_kind", "percent": 1}
          ]
        }
        """
        let usage = try XCTUnwrap(ClaudeAccountUsageDecoder.decode(Data(body.utf8), fetchedAt: .now))

        XCTAssertEqual(usage.scopedWeekly.map(\.id), ["fable", "opus-5"])
        XCTAssertEqual(usage.scopedWeekly.map(\.label), ["Fable", "Opus 5"])
        XCTAssertEqual(usage.scopedWeekly[0].window.utilizationFraction, 0.56, accuracy: 0.0001)
        XCTAssertTrue(usage.scopedWeekly[0].isActive)
        XCTAssertNotNil(usage.scopedWeekly[0].window.resetsAt)
        XCTAssertFalse(usage.scopedWeekly[1].isActive)
        XCTAssertNil(usage.scopedWeekly[1].window.resetsAt)
        XCTAssertTrue(usage.withoutScopedWeekly().scopedWeekly.isEmpty)
        XCTAssertEqual(usage.withoutScopedWeekly().sevenDay, usage.sevenDay)
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
