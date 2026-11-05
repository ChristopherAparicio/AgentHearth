import Foundation
import XCTest

@MainActor
final class LiveEventRefresherTests: XCTestCase {
    func testABurstOfEventsSharesOneRefreshAndALaterEventGetsItsOwn() async throws {
        let refresher = LiveEventRefresher(delay: .milliseconds(20))
        var refreshCount = 0
        refresher.refresh = { refreshCount += 1 }

        refresher.eventArrived()
        refresher.eventArrived()
        refresher.eventArrived()
        XCTAssertEqual(refreshCount, 0, "the refresh waits for the burst to settle")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(refreshCount, 1)

        refresher.eventArrived()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(refreshCount, 2)
    }
}
