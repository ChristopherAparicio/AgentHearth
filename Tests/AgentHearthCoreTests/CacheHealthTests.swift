import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CacheHealthTests: XCTestCase {
    func testExpectedColdStartsCountAsRequestMisses() {
        let health = CacheHealthSnapshot(
            hitCount: 9,
            avoidableMissCount: 0,
            expectedColdStartCount: 1
        )

        XCTAssertEqual(health.observedRequestCount, 10)
        XCTAssertEqual(health.hitRate, 0.9)
        XCTAssertEqual(health.band(), .healthy)
    }

    func testThresholdBands() {
        XCTAssertEqual(CacheHealthSnapshot(hitCount: 7, avoidableMissCount: 3).band(), .healthy)
        XCTAssertEqual(CacheHealthSnapshot(hitCount: 3, avoidableMissCount: 7).band(), .mixed)
        XCTAssertEqual(CacheHealthSnapshot(hitCount: 2, avoidableMissCount: 8).band(), .poor)
    }

    func testSmallSamplesRemainUnscored() {
        let health = CacheHealthSnapshot(hitCount: 1, avoidableMissCount: 3)

        XCTAssertEqual(health.hitRate, 0.25)
        XCTAssertEqual(health.band(), .insufficientData)
    }

    func testTokenReuseDoesNotReplaceRequestHitRate() {
        let health = CacheHealthSnapshot(
            hitCount: 10,
            avoidableMissCount: 0,
            observedInputTokens: 10_000,
            cachedInputTokens: 6_000
        )

        XCTAssertEqual(health.hitRate, 1)
        XCTAssertEqual(health.tokenReuseRate, 0.6)
        XCTAssertEqual(health.band(), .healthy)
    }
}
