import Foundation

/// One reading of a usage window: the share consumed, and when the provider
/// actually measured it. `measuredAt` is the provider's own measurement
/// instant (Claude's usage journal entry, Codex's rollout quota report), not
/// the poll time — an idle provider re-reports the same reading for many
/// cycles, and treating those as fresh samples would invent elapsed time.
public struct UsageBurnSample: Equatable, Sendable {
    public let fraction: Double
    public let measuredAt: Date

    public init(fraction: Double, measuredAt: Date) {
        self.fraction = min(max(fraction, 0), 1)
        self.measuredAt = measuredAt
    }
}

/// A detected burst of consumption on one usage window.
public struct UsageBurn: Equatable, Sendable {
    /// Share of the window consumed at the start of the burst.
    public let fromFraction: Double
    /// Share consumed at the newest reading.
    public let toFraction: Double
    /// Time between those two readings. Always > 0.
    public let elapsed: TimeInterval

    public init(fromFraction: Double, toFraction: Double, elapsed: TimeInterval) {
        self.fromFraction = fromFraction
        self.toFraction = toFraction
        self.elapsed = max(elapsed, 1)
    }

    public var gainedFraction: Double { max(0, toFraction - fromFraction) }

    /// Percentage points of the window consumed during the burst, rounded for
    /// display. The notification quotes points rather than tokens because the
    /// window is what the user is about to lose.
    public var gainedPoints: Int { Int((gainedFraction * 100).rounded()) }

    public var elapsedMinutes: Double { elapsed / 60 }

    public var pointsPerMinute: Double {
        guard elapsedMinutes > 0 else { return 0 }
        return gainedFraction * 100 / elapsedMinutes
    }

    /// Minutes until the window is fully consumed if this rate holds. `nil`
    /// when the window is already full or the rate is zero — a projection with
    /// no meaning is better omitted than shown as infinity.
    public var minutesToExhaustion: Double? {
        let remaining = max(0, 1 - toFraction)
        guard remaining > 0, pointsPerMinute > 0 else { return nil }
        return remaining * 100 / pointsPerMinute
    }
}

/// Decides when a usage window is being consumed abnormally fast.
///
/// The rule is deliberately stated in absolute terms — "the window gained at
/// least N points across the readings of the last M minutes" — rather than as
/// a rate. A rate computed between two polls 30 seconds apart turns a two-point
/// blip into an alarming figure, while the question the user actually asks is
/// "how much of my window just disappeared".
public enum UsageBurnPolicy {
    /// Points of a window consumed within `defaultMinutes` before it counts as
    /// a burst. A 5h window spent evenly is 0.33 points/minute; this default is
    /// roughly 4.5x that, so ordinary sustained work stays quiet.
    public static let defaultPoints = 15
    public static let defaultMinutes = 10

    /// A drop larger than this is the window rolling over into a new period,
    /// not consumption. Smaller dips are measurement noise: Codex reports
    /// several quota families and keeps the most constraining one, so the
    /// reported share can wobble slightly without any period having reset.
    static let rolloverDropFraction = 0.005

    /// Adds `sample` to a window's series, dropping readings that a rollover
    /// made meaningless and those too old to matter.
    ///
    /// Retention keeps one reading from just before the cutoff so a series
    /// always has a baseline: polling backs off while the Mac is idle, and
    /// pruning strictly to the lookback would leave a single sample and make
    /// the rule silently undetectable at exactly the moment work resumes.
    public static func appending(
        _ sample: UsageBurnSample,
        to samples: [UsageBurnSample],
        lookback: TimeInterval
    ) -> [UsageBurnSample] {
        guard let newest = samples.last else { return [sample] }
        // The same measurement re-reported: nothing new happened.
        guard sample.measuredAt > newest.measuredAt else { return samples }
        guard sample.fraction >= newest.fraction - rolloverDropFraction else { return [sample] }

        let cutoff = sample.measuredAt.addingTimeInterval(-max(0, lookback))
        let straddling = samples.last { $0.measuredAt < cutoff }
        let withinWindow = samples.filter { $0.measuredAt >= cutoff }
        return (straddling.map { [$0] } ?? []) + withinWindow + [sample]
    }

    /// The burst described by a window's series, when it reaches `points`.
    ///
    /// The baseline is the lowest reading in the series (earliest on a tie),
    /// so a dip too small to count as a rollover cannot understate the burst.
    public static func burn(in samples: [UsageBurnSample], points: Int) -> UsageBurn? {
        guard samples.count >= 2, let newest = samples.last else { return nil }
        let candidates = samples.dropLast()
        guard let baseline = candidates.min(by: { lhs, rhs in
            lhs.fraction == rhs.fraction ? lhs.measuredAt < rhs.measuredAt : lhs.fraction < rhs.fraction
        }) else { return nil }

        let elapsed = newest.measuredAt.timeIntervalSince(baseline.measuredAt)
        guard elapsed > 0 else { return nil }
        let burn = UsageBurn(
            fromFraction: baseline.fraction,
            toFraction: newest.fraction,
            elapsed: elapsed
        )
        guard burn.gainedFraction * 100 >= Double(max(1, points)) else { return nil }
        return burn
    }
}
