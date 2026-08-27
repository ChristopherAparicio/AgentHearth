import Foundation

/// Accumulates per-turn prompt-cache telemetry into the hit / avoidable-miss /
/// cold-start / unknown counts behind `CacheHealthSnapshot`. Provider adapters
/// map their wire formats into `TurnObservation`s and feed them in transcript
/// order; the wire-format differences that survive are expressed as `Policy`
/// options instead of per-adapter loops.
///
/// Pure value type: the clock never appears here — timestamps come from the
/// observations and `measuredAt` is supplied by the caller.
public struct CacheEvidenceAccumulator: Sendable {
    /// Which turn's TTL bounds the "previous turn is still cached" window that
    /// separates an avoidable miss from an expected cold start.
    public enum EligibilityWindow: Sendable {
        /// The window the previous turn established (Claude transcripts record
        /// the TTL bucket that was written; Codex infers it from the model in
        /// effect at that turn).
        case previousTurn
        /// The window inferred for the current turn (OpenCode carries model
        /// and provider per message).
        case currentTurn
    }

    /// How the session-wide token totals surface in the snapshot.
    public enum TokenTotalsReporting: Sendable {
        /// Never reported.
        case omitted
        /// Always reported, even when zero.
        case always
        /// Reported only once any prompt tokens were observed.
        case whenObserved
    }

    public struct Policy: Sendable {
        public let eligibilityWindow: EligibilityWindow
        /// When true, a miss only counts as avoidable if the previous turn
        /// used the same provider and model — switching models cannot reuse
        /// the cache, so such misses are expected cold starts.
        public let requiresStableModel: Bool
        public let tokenTotals: TokenTotalsReporting

        public init(
            eligibilityWindow: EligibilityWindow,
            requiresStableModel: Bool = false,
            tokenTotals: TokenTotalsReporting = .omitted
        ) {
            self.eligibilityWindow = eligibilityWindow
            self.requiresStableModel = requiresStableModel
            self.tokenTotals = tokenTotals
        }
    }

    public struct TurnObservation: Sendable {
        /// When the turn began. The gap from the previous turn's end to this
        /// instant is compared against the TTL window; nil forces a cold start.
        public let startedAt: Date?
        /// The instant the next turn measures its gap against; nil makes the
        /// next miss an expected cold start.
        public let endedAt: Date?
        /// false marks a turn whose token telemetry is missing entirely: it
        /// counts as unknown but still becomes the reference turn.
        public let hasTokenTelemetry: Bool
        public let cachedReadTokens: Int
        /// This turn's contribution to the observed prompt-token total.
        public let promptTokens: Int
        /// The cache TTL applying to this turn, in seconds.
        public let ttl: TimeInterval
        public let providerID: String?
        public let modelID: String?
        /// Optional identity of the turn's token totals: an observation whose
        /// signature repeats the previous one within the previous turn's TTL
        /// is a re-emission of the same turn and is ignored (Codex re-emits
        /// token_count several times per turn).
        public let signature: String?

        public init(
            startedAt: Date?,
            endedAt: Date?,
            hasTokenTelemetry: Bool = true,
            cachedReadTokens: Int = 0,
            promptTokens: Int = 0,
            ttl: TimeInterval,
            providerID: String? = nil,
            modelID: String? = nil,
            signature: String? = nil
        ) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.hasTokenTelemetry = hasTokenTelemetry
            self.cachedReadTokens = cachedReadTokens
            self.promptTokens = promptTokens
            self.ttl = ttl
            self.providerID = providerID
            self.modelID = modelID
            self.signature = signature
        }

        /// Convenience for wire formats that record one instant per turn.
        public init(
            timestamp: Date,
            cachedReadTokens: Int = 0,
            promptTokens: Int = 0,
            ttl: TimeInterval,
            signature: String? = nil
        ) {
            self.init(
                startedAt: timestamp,
                endedAt: timestamp,
                cachedReadTokens: cachedReadTokens,
                promptTokens: promptTokens,
                ttl: ttl,
                signature: signature
            )
        }
    }

    public private(set) var hitCount = 0
    public private(set) var avoidableMissCount = 0
    public private(set) var expectedColdStartCount = 0
    public private(set) var unknownCount = 0
    public private(set) var observedPromptTokens = 0
    public private(set) var cachedPromptTokens = 0

    private let policy: Policy
    private var previousEndedAt: Date?
    private var previousTTL: TimeInterval = TimeInterval(CacheTTLPolicy.fallbackTTLSeconds)
    private var previousProviderID: String?
    private var previousModelID: String?
    private var previousSignature: String?

    public init(policy: Policy) {
        self.policy = policy
    }

    public mutating func observe(_ observation: TurnObservation) {
        if let signature = observation.signature,
           signature == previousSignature,
           let previousEndedAt,
           let startedAt = observation.startedAt,
           startedAt.timeIntervalSince(previousEndedAt) <= previousTTL {
            return
        }

        guard observation.hasTokenTelemetry else {
            unknownCount += 1
            rememberPrevious(observation)
            return
        }

        observedPromptTokens += max(0, observation.promptTokens)
        cachedPromptTokens += max(0, observation.cachedReadTokens)

        if observation.cachedReadTokens > 0 {
            hitCount += 1
        } else if isEligibleMiss(observation) {
            avoidableMissCount += 1
        } else {
            expectedColdStartCount += 1
        }
        rememberPrevious(observation)
    }

    public func snapshot(measuredAt: Date) -> CacheHealthSnapshot? {
        guard hitCount + avoidableMissCount + expectedColdStartCount + unknownCount > 0 else {
            return nil
        }
        let totals: (observed: Int?, cached: Int?) = switch policy.tokenTotals {
        case .omitted:
            (nil, nil)
        case .always:
            (observedPromptTokens, cachedPromptTokens)
        case .whenObserved:
            observedPromptTokens > 0 ? (observedPromptTokens, cachedPromptTokens) : (nil, nil)
        }
        return CacheHealthSnapshot(
            hitCount: hitCount,
            avoidableMissCount: avoidableMissCount,
            expectedColdStartCount: expectedColdStartCount,
            unknownCount: unknownCount,
            measuredAt: measuredAt,
            observedInputTokens: totals.observed,
            cachedInputTokens: totals.cached
        )
    }

    private func isEligibleMiss(_ observation: TurnObservation) -> Bool {
        guard let previousEndedAt, let startedAt = observation.startedAt else { return false }
        if policy.requiresStableModel,
           observation.modelID != previousModelID || observation.providerID != previousProviderID {
            return false
        }
        let window = switch policy.eligibilityWindow {
        case .previousTurn: previousTTL
        case .currentTurn: observation.ttl
        }
        return startedAt.timeIntervalSince(previousEndedAt) <= window
    }

    private mutating func rememberPrevious(_ observation: TurnObservation) {
        previousEndedAt = observation.endedAt
        previousTTL = observation.ttl
        previousProviderID = observation.providerID
        previousModelID = observation.modelID
        previousSignature = observation.signature
    }
}
