import Foundation

public enum CacheHealthBand: String, Codable, Sendable {
    case healthy
    case mixed
    case poor
    case insufficientData
}

public struct CacheHealthPolicy: Codable, Equatable, Sendable {
    public let minimumEligibleRequests: Int
    public let healthyThreshold: Double
    public let mixedThreshold: Double

    public init(
        minimumEligibleRequests: Int = 5,
        healthyThreshold: Double = 0.70,
        mixedThreshold: Double = 0.30
    ) {
        precondition(minimumEligibleRequests > 0)
        precondition((0...1).contains(healthyThreshold))
        precondition((0...1).contains(mixedThreshold))
        precondition(mixedThreshold <= healthyThreshold)

        self.minimumEligibleRequests = minimumEligibleRequests
        self.healthyThreshold = healthyThreshold
        self.mixedThreshold = mixedThreshold
    }

    public static let standard = CacheHealthPolicy()
}

/// Request-level cache effectiveness for requests with usable cache telemetry.
/// Expected cold starts remain a separate diagnostic category, but they count
/// as misses in the hit rate: nine cached requests out of ten is 90% Hits.
public struct CacheHealthSnapshot: Codable, Equatable, Sendable {
    public let hitCount: Int
    public let avoidableMissCount: Int
    public let expectedColdStartCount: Int
    public let unknownCount: Int
    public let measuredAt: Date
    public let observedInputTokens: Int?
    public let cachedInputTokens: Int?

    public init(
        hitCount: Int,
        avoidableMissCount: Int,
        expectedColdStartCount: Int = 0,
        unknownCount: Int = 0,
        measuredAt: Date = .now,
        observedInputTokens: Int? = nil,
        cachedInputTokens: Int? = nil
    ) {
        self.hitCount = max(0, hitCount)
        self.avoidableMissCount = max(0, avoidableMissCount)
        self.expectedColdStartCount = max(0, expectedColdStartCount)
        self.unknownCount = max(0, unknownCount)
        self.measuredAt = measuredAt
        self.observedInputTokens = observedInputTokens.map { max(0, $0) }
        self.cachedInputTokens = cachedInputTokens.map { max(0, $0) }
    }

    /// Cold starts count as observed because the product reports the literal
    /// request hit rate rather than an avoidable-miss efficiency score.
    public var observedRequestCount: Int {
        hitCount + avoidableMissCount + expectedColdStartCount
    }

    public var hitRate: Double? {
        guard observedRequestCount > 0 else { return nil }
        return Double(hitCount) / Double(observedRequestCount)
    }

    /// Fraction of observed input tokens actually read from the provider cache.
    /// Unlike request hit rate, this distinguishes a tiny cached prefix from a
    /// request whose input was almost entirely reused.
    public var tokenReuseRate: Double? {
        guard let observedInputTokens, observedInputTokens > 0,
              let cachedInputTokens
        else { return nil }
        return min(1, Double(cachedInputTokens) / Double(observedInputTokens))
    }

    public func band(using policy: CacheHealthPolicy = .standard) -> CacheHealthBand {
        guard observedRequestCount >= policy.minimumEligibleRequests,
              let hitRate
        else {
            return .insufficientData
        }

        if hitRate >= policy.healthyThreshold {
            return .healthy
        }
        if hitRate >= policy.mixedThreshold {
            return .mixed
        }
        return .poor
    }
}
