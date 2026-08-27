import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CacheActivityAggregateTests: XCTestCase {
    private struct Aggregate: CacheActivityAggregate {
        let inputTokens: Int
        let cachedInputTokens: Int
        let turnCount: Int
        let hitCount: Int
    }

    func testDerivedRates() throws {
        let aggregate = Aggregate(inputTokens: 10_000, cachedInputTokens: 1_800, turnCount: 8, hitCount: 4)

        XCTAssertEqual(aggregate.uncachedInputTokens, 8_200)
        XCTAssertEqual(try XCTUnwrap(aggregate.cacheReuseRate), 0.18, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(aggregate.hitRate), 0.5, accuracy: 0.0001)
    }

    func testEmptyAggregateReportsNilRates() {
        let aggregate = Aggregate(inputTokens: 0, cachedInputTokens: 0, turnCount: 0, hitCount: 0)

        XCTAssertEqual(aggregate.uncachedInputTokens, 0)
        XCTAssertNil(aggregate.cacheReuseRate)
        XCTAssertNil(aggregate.hitRate)
    }

    func testUncachedTokensNeverGoNegative() {
        // Cached tokens can transiently exceed observed input when providers
        // report the counters at different times.
        let aggregate = Aggregate(inputTokens: 100, cachedInputTokens: 250, turnCount: 1, hitCount: 1)

        XCTAssertEqual(aggregate.uncachedInputTokens, 0)
    }

    func testHistoryTypesShareTheDerivations() throws {
        let bucket = CacheHistoryBucket(
            day: Date(timeIntervalSince1970: 0),
            turnCount: 4,
            hitCount: 3,
            inputTokens: 1_000,
            cachedInputTokens: 750,
            outputTokens: 50
        )
        let snapshot = HistoryDashboardSnapshot(
            startsAt: Date(timeIntervalSince1970: 0),
            endsAt: Date(timeIntervalSince1970: 86_400),
            buckets: [bucket],
            sessions: [],
            projects: [],
            storageBytes: 0
        )

        XCTAssertEqual(bucket.uncachedInputTokens, 250)
        XCTAssertEqual(try XCTUnwrap(bucket.cacheReuseRate), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(bucket.hitRate), 0.75, accuracy: 0.0001)
        XCTAssertEqual(snapshot.uncachedInputTokens, 250)
        XCTAssertEqual(try XCTUnwrap(snapshot.cacheReuseRate), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.hitRate), 0.75, accuracy: 0.0001)
    }
}
