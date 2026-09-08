import Foundation
import XCTest
@testable import AgentHearthDomain

final class UsageBurnPolicyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let lookback: TimeInterval = 10 * 60

    private func sample(_ fraction: Double, _ minutes: Double) -> UsageBurnSample {
        UsageBurnSample(fraction: fraction, measuredAt: epoch.addingTimeInterval(minutes * 60))
    }

    private func series(_ points: [(Double, Double)]) -> [UsageBurnSample] {
        points.reduce(into: [UsageBurnSample]()) { samples, point in
            samples = UsageBurnPolicy.appending(
                sample(point.0, point.1),
                to: samples,
                lookback: lookback
            )
        }
    }

    func testIgnoresAReReportedMeasurement() {
        // An idle provider republishes the same reading every poll; treating
        // those as new samples would invent elapsed time at a flat fraction.
        var samples = UsageBurnPolicy.appending(sample(0.2, 0), to: [], lookback: lookback)
        samples = UsageBurnPolicy.appending(sample(0.2, 0), to: samples, lookback: lookback)
        samples = UsageBurnPolicy.appending(sample(0.2, 0), to: samples, lookback: lookback)

        XCTAssertEqual(samples.count, 1)
    }

    func testRolloverStartsANewSeries() {
        let samples = series([(0.80, 0), (0.88, 2), (0.03, 4)])

        XCTAssertEqual(samples.map(\.fraction), [0.03])
        XCTAssertNil(UsageBurnPolicy.burn(in: samples, points: 15))
    }

    func testKeepsOneReadingOlderThanTheLookbackAsABaseline() {
        // Polling backs off while the Mac is idle. Pruning strictly to the
        // lookback would leave a single sample and make the rule undetectable
        // at exactly the moment work resumes.
        let samples = series([(0.10, 0), (0.12, 2), (0.40, 15)])

        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.first?.fraction, 0.12)
    }

    func testDetectsARiseThatReachesTheThreshold() {
        let burn = UsageBurnPolicy.burn(in: series([(0.20, 0), (0.30, 3), (0.44, 6)]), points: 15)

        XCTAssertEqual(burn?.gainedPoints, 24)
        XCTAssertEqual(burn?.elapsed, 6 * 60)
        XCTAssertEqual(burn?.fromFraction, 0.20)
        XCTAssertEqual(burn?.toFraction, 0.44)
    }

    func testStaysQuietBelowTheThreshold() {
        XCTAssertNil(UsageBurnPolicy.burn(in: series([(0.20, 0), (0.28, 4), (0.33, 8)]), points: 15))
    }

    func testNeedsTwoReadings() {
        XCTAssertNil(UsageBurnPolicy.burn(in: series([(0.90, 0)]), points: 15))
    }

    func testBaselineIsTheLowestReadingNotTheFirst() {
        // A dip too small to be a rollover is measurement noise — Codex keeps
        // the most constraining of several quota families, so the reported
        // share can wobble. The burst is measured from the lowest reading.
        let burn = UsageBurnPolicy.burn(in: series([(0.204, 0), (0.201, 2), (0.36, 5)]), points: 15)

        XCTAssertEqual(burn?.fromFraction, 0.201)
        XCTAssertEqual(burn?.elapsed, 3 * 60)
    }

    func testProjectsTimeToExhaustion() throws {
        // 20 points over 10 minutes is 2 points/minute; 60 points remain.
        let burn = UsageBurn(fromFraction: 0.20, toFraction: 0.40, elapsed: 10 * 60)

        XCTAssertEqual(burn.pointsPerMinute, 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(burn.minutesToExhaustion), 30, accuracy: 0.0001)
    }

    func testOmitsTheProjectionForAFullWindow() {
        XCTAssertNil(UsageBurn(fromFraction: 0.80, toFraction: 1.0, elapsed: 60).minutesToExhaustion)
    }
}
