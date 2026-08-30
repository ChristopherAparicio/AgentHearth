import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CompactDurationTests: XCTestCase {
    func testRendersTwoLargestUnits() {
        XCTAssertEqual(CompactDuration(4 * 86_400 + 5 * 3_600).text, "4d5h")
        XCTAssertEqual(CompactDuration(2 * 3_600 + 40 * 60).text, "2h40m")
        XCTAssertEqual(CompactDuration(45 * 60).text, "45m")
    }

    func testDropsZeroTrailingUnit() {
        XCTAssertEqual(CompactDuration(4 * 86_400).text, "4d")
        XCTAssertEqual(CompactDuration(3 * 3_600).text, "3h")
    }

    func testSubMinuteCollapses() {
        XCTAssertEqual(CompactDuration(30).text, "<1m")
        XCTAssertEqual(CompactDuration(0).text, "<1m")
        XCTAssertEqual(CompactDuration(-100).text, "<1m")
    }

    func testFiveHourWindowStaysHoursMinutes() {
        // A five-hour window is always under a day, so it renders h/m.
        XCTAssertEqual(CompactDuration(4 * 3_600 + 12 * 60).text, "4h12m")
    }

    func testUntilReturnsNilOnceElapsed() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(CompactDuration.until(Date(timeIntervalSince1970: 9_999), now: now))
        XCTAssertEqual(
            CompactDuration.until(Date(timeIntervalSince1970: 10_000 + 3_600), now: now)?.text,
            "1h"
        )
    }
}
