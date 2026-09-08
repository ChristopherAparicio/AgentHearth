import Foundation

/// One stored reading of a usage window.
public struct UsageTimelinePoint: Identifiable, Equatable, Sendable {
    public let measuredAt: Date
    public let usedFraction: Double

    public var id: Date { measuredAt }

    public init(measuredAt: Date, usedFraction: Double) {
        self.measuredAt = measuredAt
        self.usedFraction = min(max(usedFraction, 0), 1)
    }
}

/// The fastest stretch found in a window's trace: where the window actually
/// went. This is the answer to "half my window disappeared, when?" — the pair
/// of readings between which it disappeared.
public struct UsageSurge: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let fromFraction: Double
    public let toFraction: Double

    public init(startedAt: Date, endedAt: Date, fromFraction: Double, toFraction: Double) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.fromFraction = fromFraction
        self.toFraction = toFraction
    }

    public var gainedPoints: Double { max(0, toFraction - fromFraction) * 100 }
    public var elapsed: TimeInterval { max(1, endedAt.timeIntervalSince(startedAt)) }
    public var pointsPerMinute: Double { gainedPoints / (elapsed / 60) }
}

/// The trace of one usage window across the inspected range.
public struct UsageTimeline: Identifiable, Equatable, Sendable {
    public let providerID: AgentProviderID
    public let windowID: String
    public let label: String
    /// The machine whose account reported this window. Two hosts can run the
    /// same provider under different accounts, and merging their readings
    /// would invent consumption that never happened.
    public let hostName: String
    /// Readings in measurement order, oldest first.
    public let points: [UsageTimelinePoint]

    public var id: String { "\(providerID.rawValue):\(windowID):\(hostName)" }

    public init(
        providerID: AgentProviderID,
        windowID: String,
        label: String,
        hostName: String,
        points: [UsageTimelinePoint]
    ) {
        self.providerID = providerID
        self.windowID = windowID
        self.label = label
        self.hostName = hostName
        self.points = points
    }

    /// A drop larger than this is the window rolling over into a new period.
    private static let rolloverDropFraction = UsageBurnPolicy.rolloverDropFraction

    /// Points of the window spent across the range.
    ///
    /// The sum of the rises between consecutive readings rather than
    /// last-minus-first: a 5h window that reset mid-range would otherwise
    /// report a negative or absurdly small figure for a range in which real
    /// work happened.
    public var consumedPoints: Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + max(0, pair.1.usedFraction - pair.0.usedFraction) * 100
        }
    }

    public var latestFraction: Double? { points.last?.usedFraction }

    /// The steepest stretch between two consecutive readings.
    ///
    /// Ranked by rate, not by total gain: with irregular polling the largest
    /// step is often just the longest gap. A minimum gain keeps measurement
    /// noise between two near-simultaneous readings from winning on rate
    /// alone, and rollovers are skipped since a reset is not consumption.
    public var steepestSurge: UsageSurge? {
        zip(points, points.dropFirst())
            .filter { $0.1.usedFraction >= $0.0.usedFraction - Self.rolloverDropFraction }
            .map { UsageSurge(
                startedAt: $0.0.measuredAt,
                endedAt: $0.1.measuredAt,
                fromFraction: $0.0.usedFraction,
                toFraction: $0.1.usedFraction
            ) }
            .filter { $0.gainedPoints >= 1 }
            .max { $0.pointsPerMinute < $1.pointsPerMinute }
    }
}

/// What the consumption view shows for one range: how each usage window moved,
/// and which sessions were measured spending tokens while it moved.
public struct ConsumptionSnapshot: Equatable, Sendable {
    public let startsAt: Date
    public let endsAt: Date
    public let timelines: [UsageTimeline]
    /// Sessions with a measured turn in the range, costliest first.
    public let sessions: [SessionHistorySummary]

    public init(
        startsAt: Date,
        endsAt: Date,
        timelines: [UsageTimeline],
        sessions: [SessionHistorySummary]
    ) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timelines = timelines
        self.sessions = sessions
    }

    public static let empty = ConsumptionSnapshot(
        startsAt: .now,
        endsAt: .now,
        timelines: [],
        sessions: []
    )
}
