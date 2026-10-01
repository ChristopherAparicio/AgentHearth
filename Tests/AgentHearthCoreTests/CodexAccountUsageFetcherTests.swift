import Foundation
import XCTest
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CodexAccountUsageFetcherTests: XCTestCase {
    /// A live payload taken while the weekly quota was spent: the binding
    /// limit sits at 100% under `rate_limit`, while the reserve the CLI had
    /// switched to reads 0% under `additional_rate_limits`. Reading the
    /// reserve is exactly the mistake that made the dashboard show a reset.
    func testReadsTheBindingLimitAndIgnoresTheReserve() throws {
        let payload = Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "allowed": false,
            "limit_reached": true,
            "primary_window": {
              "used_percent": 100,
              "limit_window_seconds": 604800,
              "reset_at": 1790234984
            },
            "secondary_window": null
          },
          "additional_rate_limits": [
            {
              "limit_name": "gpt-reserve",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 0,
                  "limit_window_seconds": 604800,
                  "reset_at": 1790515422
                }
              }
            }
          ]
        }
        """.utf8)

        let windows = try XCTUnwrap(
            CodexAccountUsageFetcher.windows(from: payload, measuredAt: Date(timeIntervalSince1970: 1_000))
        )
        XCTAssertEqual(windows.count, 1)
        let weekly = try XCTUnwrap(windows.first)
        XCTAssertEqual(weekly.id, "codex-10080")
        XCTAssertEqual(weekly.label, "7 days")
        XCTAssertEqual(weekly.usedFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_790_234_984))
        XCTAssertEqual(weekly.measuredAt, Date(timeIntervalSince1970: 1_000))
    }

    func testBothWindowsAreRead() throws {
        let payload = Data("""
        {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":100},
         "secondary_window":{"used_percent":80,"limit_window_seconds":604800,"reset_at":900}}}
        """.utf8)

        let windows = try XCTUnwrap(
            CodexAccountUsageFetcher.windows(from: payload, measuredAt: Date(timeIntervalSince1970: 1))
        )
        XCTAssertEqual(windows.map(\.label).sorted(), ["5 hours", "7 days"])
    }

    /// An unrecognised or empty body must read as "no answer", so the caller
    /// keeps the rollout figure instead of blanking the quota.
    func testUnusableBodyYieldsNothing() {
        let measuredAt = Date(timeIntervalSince1970: 1)
        XCTAssertNil(CodexAccountUsageFetcher.windows(from: Data("not json".utf8), measuredAt: measuredAt))
        XCTAssertNil(CodexAccountUsageFetcher.windows(from: Data("{}".utf8), measuredAt: measuredAt))
        XCTAssertNil(CodexAccountUsageFetcher.windows(
            from: Data(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#.utf8),
            measuredAt: measuredAt
        ))
    }
}
