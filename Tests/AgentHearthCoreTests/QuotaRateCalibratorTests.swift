import Foundation
import XCTest
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class QuotaRateCalibratorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func hour(_ h: Double) -> Date { base.addingTimeInterval(h * 3_600) }

    private func timeline(_ readings: [(Double, Double)], provider: AgentProviderID = .claudeCode) -> UsageTimeline {
        UsageTimeline(
            providerID: provider,
            windowID: provider == .claudeCode ? "claude-7d" : "codex-10080",
            label: "7 days",
            hostName: "This Mac",
            points: readings.map { UsageTimelinePoint(measuredAt: hour($0.0), usedFraction: $0.1) }
        )
    }

    /// Output-only spend worth `dollars` at Opus 5.5's $20/M.
    private func opusOutput(at h: Double, dollars: Double, model: String? = "claude-opus-5-5") -> TokenSpend {
        TokenSpend(occurredAt: hour(h), model: model, uncachedInput: 0, cacheRead: 0, output: Int(dollars / 20 * 1_000_000))
    }

    func testRecoversTheCostOfAPointAndDerivesPerTypeRates() throws {
        // Four rises of 3 points, each carrying $72 of tokens: $24 a point.
        let readings = [(0.0, 0.10), (1, 0.13), (2, 0.16), (3, 0.19), (4, 0.22)]
        let spends = (0..<4).map { opusOutput(at: Double($0) + 0.5, dollars: 72) }

        let estimate = try XCTUnwrap(QuotaRateCalibrator.estimate(timeline: timeline(readings), spends: spends))

        XCTAssertEqual(estimate.dollarsPerPoint, 24, accuracy: 0.01)
        XCTAssertEqual(estimate.referenceModel, "claude-opus-5-5")
        XCTAssertEqual(estimate.pointsPerMillion.output, 20.0 / 24, accuracy: 0.001)
        XCTAssertEqual(estimate.pointsPerMillion.cacheRead, 0.2 / 24, accuracy: 0.0001)
        // Claude's uncached input is priced as one-hour cache writes ($8/M).
        XCTAssertEqual(estimate.pointsPerMillion.uncachedInput, 8.0 / 24, accuracy: 0.001)
    }

    /// Use the machine never saw — claude.ai, another computer — raises the
    /// window with no token to show for it. That rise looks cheap per point
    /// and is the one left out.
    func testARiseMostlyFromUnseenUseIsLeftOut() throws {
        let readings = [(0.0, 0.10), (1, 0.13), (2, 0.16), (3, 0.19), (4, 0.22)]
        let spends = [
            opusOutput(at: 0.5, dollars: 72),
            opusOutput(at: 1.5, dollars: 72),
            opusOutput(at: 2.5, dollars: 12),   // 3 points, $12 seen: mostly elsewhere
            opusOutput(at: 3.5, dollars: 72),
        ]

        let estimate = try XCTUnwrap(QuotaRateCalibrator.estimate(timeline: timeline(readings), spends: spends))

        XCTAssertEqual(estimate.dollarsPerPoint, 24, accuracy: 0.01)
        XCTAssertEqual(estimate.increases, 3)
    }

    func testAWindowResetIsNotARise() throws {
        // 0.30 → 0.36 rises, then the week resets to 0.02 and rises again.
        let readings = [(0.0, 0.30), (1, 0.33), (2, 0.36), (3, 0.02), (4, 0.05), (5, 0.08)]
        let spends = [
            opusOutput(at: 0.5, dollars: 72), opusOutput(at: 1.5, dollars: 72),
            opusOutput(at: 2.5, dollars: 5_000),    // across the reset: must not count
            opusOutput(at: 3.5, dollars: 72), opusOutput(at: 4.5, dollars: 72),
        ]

        let estimate = try XCTUnwrap(QuotaRateCalibrator.estimate(timeline: timeline(readings), spends: spends))

        XCTAssertEqual(estimate.dollarsPerPoint, 24, accuracy: 0.01)
        XCTAssertEqual(estimate.points, 9, accuracy: 0.001)
    }

    /// A model with no known price is left out — Codex's reserve draws on a
    /// different limit — while a spend with no model at all is priced as the
    /// reference model.
    func testUnpricedModelsAreLeftOutAndUnnamedOnesPricedAsTheReference() throws {
        let readings = [(0.0, 0.10), (1, 0.13), (2, 0.16), (3, 0.19)]
        var spends = (0..<3).map { opusOutput(at: Double($0) + 0.5, dollars: 72) }
        spends.append(opusOutput(at: 0.6, dollars: 10_000, model: "gpt-reserve"))
        spends.append(opusOutput(at: 1.6, dollars: 0.000001, model: nil))

        let estimate = try XCTUnwrap(QuotaRateCalibrator.estimate(timeline: timeline(readings), spends: spends))

        XCTAssertEqual(estimate.dollarsPerPoint, 24, accuracy: 0.01)
    }

    func testTooFewRisesGiveNoEstimate() {
        let readings = [(0.0, 0.10), (1, 0.13), (2, 0.16)]
        let spends = [opusOutput(at: 0.5, dollars: 72), opusOutput(at: 1.5, dollars: 72)]
        XCTAssertNil(QuotaRateCalibrator.estimate(timeline: timeline(readings), spends: spends))
    }

    func testRisesWithNoRecordedTokenAreIgnored() {
        // Three rises, but one has nothing recorded: two remain, not enough.
        let readings = [(0.0, 0.10), (1, 0.13), (2, 0.16), (3, 0.19)]
        let spends = [opusOutput(at: 0.5, dollars: 72), opusOutput(at: 2.5, dollars: 72)]
        XCTAssertNil(QuotaRateCalibrator.estimate(timeline: timeline(readings), spends: spends))
    }

    /// End to end through the store: windows read from snapshots, per-request
    /// rows recorded from sessions, and the turn rows of the old recording
    /// left out of the calibration.
    func testTheStoreCalibratesFromRecordedRequestsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentHearth-QuotaRates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appending(path: "history.sqlite"))
        let start = Date.now.addingTimeInterval(-6 * 3_600)
        func at(_ h: Double) -> Date { start.addingTimeInterval(h * 3_600) }

        var requests: [TokenUsageRecord] = []
        for h in 0..<5 {
            let fraction = 0.10 + 0.03 * Double(h)
            if h > 0 {
                requests.append(TokenUsageRecord(
                    id: "r\(h)", occurredAt: at(Double(h) - 0.5), model: "claude-opus-5-5",
                    inputTokens: 0, cachedReadTokens: 1, cacheWriteTokens: 0, outputTokens: 3_600_000
                ))
            }
            let session = AgentSession(
                id: "s", providerID: .claudeCode, title: "Claude Code · demo", projectName: "demo",
                status: .idle, lastActivityAt: at(Double(h)),
                target: SessionTarget(providerID: .claudeCode, sessionID: "s", workingDirectory: nil),
                requests: requests
            )
            await store.ingest([ProviderSnapshot(
                id: .claudeCode, connectionState: .connected, sessions: [session],
                usageWindows: [UsageWindow(id: "claude-7d", label: "7 days", usedFraction: fraction, measuredAt: at(Double(h)))],
                updatedAt: at(Double(h))
            )], retentionDays: 30)
        }

        let estimates = await store.quotaRates(days: 7)
        let weekly = try XCTUnwrap(estimates.first { $0.windowID == "claude-7d" })
        // Each request carries one cached token: the recorder skips requests
        // with no input at all, and one token moves the cost by a millionth.
        XCTAssertEqual(weekly.dollarsPerPoint, 24, accuracy: 0.5)
    }

    /// What happened on the first launch with per-request recording: windows
    /// had been read for hours, then a single pass wrote past requests in one
    /// go — only those still within the part of each transcript that is read.
    /// Those hours are partly recorded and must not be calibrated on.
    func testRequestsWrittenAllAtOnceWhenRecordingBeginsAreNotCalibratedOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentHearth-QuotaBackfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(databaseURL: directory.appending(path: "history.sqlite"))
        let start = Date.now.addingTimeInterval(-6 * 3_600)
        func at(_ h: Double) -> Date { start.addingTimeInterval(h * 3_600) }
        func snapshot(_ h: Double, fraction: Double, requests: [TokenUsageRecord]) -> ProviderSnapshot {
            ProviderSnapshot(
                id: .claudeCode, connectionState: .connected,
                sessions: [AgentSession(
                    id: "s", providerID: .claudeCode, title: "Claude Code · demo", projectName: "demo",
                    status: .idle, lastActivityAt: at(h),
                    target: SessionTarget(providerID: .claudeCode, sessionID: "s", workingDirectory: nil),
                    requests: requests
                )],
                usageWindows: [UsageWindow(id: "claude-7d", label: "7 days", usedFraction: fraction, measuredAt: at(h))],
                updatedAt: at(h)
            )
        }
        // Readings recorded live, before any request was.
        for h in 0..<5 { await store.ingest([snapshot(Double(h), fraction: 0.10 + 0.03 * Double(h), requests: [])], retentionDays: 30) }
        // Then one pass writes the past requests at once.
        let backfill = (1..<5).map { h in
            TokenUsageRecord(id: "r\(h)", occurredAt: at(Double(h) - 0.5), model: "claude-opus-5-5",
                             inputTokens: 0, cachedReadTokens: 1, cacheWriteTokens: 0, outputTokens: 3_600_000)
        }
        await store.ingest([snapshot(4, fraction: 0.22, requests: backfill)], retentionDays: 30)

        let estimates = await store.quotaRates(days: 7)
        XCTAssertTrue(estimates.isEmpty, "nothing was recorded live after recording began")
    }

    /// A source dropping out made the card fall back to an hours-old, lower
    /// reading; recorded, it read as a reset and a recovery that never were.
    func testAReadingOlderThanTheLastRecordedOneIsNotStored() {
        let last = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(UsageSampleGranularity.shouldStore(
            fraction: 0.02, measuredAt: last.addingTimeInterval(-3_600), lastFraction: 0.47, lastMeasuredAt: last
        ))
        XCTAssertTrue(UsageSampleGranularity.shouldStore(
            fraction: 0.48, measuredAt: last.addingTimeInterval(5), lastFraction: 0.47, lastMeasuredAt: last
        ))
    }
}
