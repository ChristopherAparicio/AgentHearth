import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class CacheEvidenceAccumulatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testCachedReadTokensCountAsHits() {
        var accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .previousTurn))
        accumulator.observe(.init(timestamp: base, cachedReadTokens: 500, ttl: 300))

        let snapshot = accumulator.snapshot(measuredAt: base)
        XCTAssertEqual(snapshot?.hitCount, 1)
        XCTAssertEqual(snapshot?.avoidableMissCount, 0)
        XCTAssertEqual(snapshot?.expectedColdStartCount, 0)
    }

    func testPreviousTurnWindowSeparatesMissesFromColdStarts() {
        var accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .previousTurn))
        // First turn is always a cold start; the second lands inside the TTL
        // the first established, the third far outside it.
        accumulator.observe(.init(timestamp: base, ttl: 300))
        accumulator.observe(.init(timestamp: base.addingTimeInterval(200), ttl: 300))
        accumulator.observe(.init(timestamp: base.addingTimeInterval(1_000), ttl: 300))

        let snapshot = accumulator.snapshot(measuredAt: base)
        XCTAssertEqual(snapshot?.avoidableMissCount, 1)
        XCTAssertEqual(snapshot?.expectedColdStartCount, 2)
    }

    func testPreviousTurnWindowUsesTheTTLThePreviousTurnEstablished() {
        var accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .previousTurn))
        accumulator.observe(.init(timestamp: base, ttl: 3_600))
        // 1000s gap exceeds this turn's own 300s TTL but not the previous
        // turn's hour-long window.
        accumulator.observe(.init(timestamp: base.addingTimeInterval(1_000), ttl: 300))

        XCTAssertEqual(accumulator.avoidableMissCount, 1)
        XCTAssertEqual(accumulator.expectedColdStartCount, 1)
    }

    func testCurrentTurnWindowUsesTheCurrentObservationTTL() {
        var accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .currentTurn))
        accumulator.observe(.init(timestamp: base, ttl: 300))
        // 1000s gap exceeds the previous turn's TTL but the current turn's
        // 30-minute policy still covers it.
        accumulator.observe(.init(timestamp: base.addingTimeInterval(1_000), ttl: 1_800))

        XCTAssertEqual(accumulator.avoidableMissCount, 1)
        XCTAssertEqual(accumulator.expectedColdStartCount, 1)
    }

    func testStableModelRequirementTurnsModelSwitchesIntoColdStarts() {
        var accumulator = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .currentTurn, requiresStableModel: true)
        )
        accumulator.observe(.init(
            startedAt: base,
            endedAt: base,
            ttl: 300,
            providerID: "openai",
            modelID: "gpt-5.6-sol"
        ))
        accumulator.observe(.init(
            startedAt: base.addingTimeInterval(100),
            endedAt: base.addingTimeInterval(100),
            ttl: 300,
            providerID: "anthropic",
            modelID: "claude-fable-5"
        ))
        accumulator.observe(.init(
            startedAt: base.addingTimeInterval(200),
            endedAt: base.addingTimeInterval(200),
            ttl: 300,
            providerID: "anthropic",
            modelID: "claude-fable-5"
        ))

        XCTAssertEqual(accumulator.avoidableMissCount, 1)
        XCTAssertEqual(accumulator.expectedColdStartCount, 2)
    }

    func testTelemetryFreeTurnsCountAsUnknownAndBecomeTheReferenceTurn() {
        var accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .currentTurn))
        accumulator.observe(.init(
            startedAt: base,
            endedAt: base,
            hasTokenTelemetry: false,
            ttl: 300
        ))
        accumulator.observe(.init(
            startedAt: base.addingTimeInterval(100),
            endedAt: base.addingTimeInterval(100),
            ttl: 300
        ))

        XCTAssertEqual(accumulator.unknownCount, 1)
        XCTAssertEqual(accumulator.avoidableMissCount, 1)
        XCTAssertEqual(accumulator.expectedColdStartCount, 0)
    }

    func testMissingTimestampsForceColdStarts() {
        var accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .currentTurn))
        // The first turn never records an end, so the second cannot prove the
        // cache was still warm.
        accumulator.observe(.init(startedAt: base, endedAt: nil, ttl: 300))
        accumulator.observe(.init(
            startedAt: base.addingTimeInterval(100),
            endedAt: base.addingTimeInterval(100),
            ttl: 300
        ))

        XCTAssertEqual(accumulator.expectedColdStartCount, 2)
        XCTAssertEqual(accumulator.avoidableMissCount, 0)
    }

    func testRepeatedSignatureWithinWindowIsIgnored() {
        var accumulator = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .previousTurn, tokenTotals: .always)
        )
        accumulator.observe(.init(
            timestamp: base,
            cachedReadTokens: 400,
            promptTokens: 1_000,
            ttl: 300,
            signature: "1000|400|0|10"
        ))
        // Same turn re-emitted moments later: no extra hit, no double counting.
        accumulator.observe(.init(
            timestamp: base.addingTimeInterval(10),
            cachedReadTokens: 400,
            promptTokens: 1_000,
            ttl: 300,
            signature: "1000|400|0|10"
        ))
        // The same totals recurring after the window count as a new turn.
        accumulator.observe(.init(
            timestamp: base.addingTimeInterval(1_000),
            cachedReadTokens: 400,
            promptTokens: 1_000,
            ttl: 300,
            signature: "1000|400|0|10"
        ))

        XCTAssertEqual(accumulator.hitCount, 2)
        XCTAssertEqual(accumulator.observedPromptTokens, 2_000)
        XCTAssertEqual(accumulator.cachedPromptTokens, 800)
    }

    func testTokenTotalsReportingModes() {
        let observation = CacheEvidenceAccumulator.TurnObservation(
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            cachedReadTokens: 300,
            promptTokens: 1_000,
            ttl: 300
        )

        var omitted = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .currentTurn, tokenTotals: .omitted)
        )
        omitted.observe(observation)
        XCTAssertNil(omitted.snapshot(measuredAt: base)?.observedInputTokens)
        XCTAssertNil(omitted.snapshot(measuredAt: base)?.cachedInputTokens)

        var always = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .previousTurn, tokenTotals: .always)
        )
        always.observe(.init(timestamp: base, ttl: 300))
        XCTAssertEqual(always.snapshot(measuredAt: base)?.observedInputTokens, 0)
        XCTAssertEqual(always.snapshot(measuredAt: base)?.cachedInputTokens, 0)

        var whenObserved = CacheEvidenceAccumulator(
            policy: .init(eligibilityWindow: .previousTurn, tokenTotals: .whenObserved)
        )
        whenObserved.observe(.init(timestamp: base, ttl: 300))
        XCTAssertNil(whenObserved.snapshot(measuredAt: base)?.observedInputTokens)
        whenObserved.observe(observation)
        XCTAssertEqual(whenObserved.snapshot(measuredAt: base)?.observedInputTokens, 1_000)
        XCTAssertEqual(whenObserved.snapshot(measuredAt: base)?.cachedInputTokens, 300)
    }

    func testSnapshotIsNilWithoutObservations() {
        let accumulator = CacheEvidenceAccumulator(policy: .init(eligibilityWindow: .previousTurn))
        XCTAssertNil(accumulator.snapshot(measuredAt: base))
    }
}
