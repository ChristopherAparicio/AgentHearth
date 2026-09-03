import AgentHearthApplication
import AgentHearthDomain
import Foundation

extension CodexConnector {
    /// Maps one token_count emission into an accumulator observation. Codex
    /// re-emits the same turn's totals several times, so the observation
    /// carries a signature the accumulator uses to collapse re-emissions
    /// within the cache window; emissions with no token movement at all are
    /// dropped here instead of counting as turns.
    static func evidenceObservation(
        for usage: CodexTokenUsage?,
        at timestamp: Date,
        model: String?
    ) -> CacheEvidenceAccumulator.TurnObservation? {
        guard let usage else { return nil }
        let input = usage.inputTokens ?? 0
        let cached = usage.cachedInputTokens ?? 0
        let written = usage.cacheWriteInputTokens ?? 0
        guard input > 0 || cached > 0 || written > 0 else { return nil }
        return CacheEvidenceAccumulator.TurnObservation(
            timestamp: timestamp,
            cachedReadTokens: cached,
            promptTokens: input,
            ttl: TimeInterval(CacheTTLPolicy.ttlSeconds(openAIModel: model)),
            signature: "\(input)|\(cached)|\(written)|\(usage.outputTokens ?? 0)"
        )
    }

    static func parseDate(_ value: String) -> Date? {
        ISO8601Instant.parse(value)
    }
}

struct FileCandidate {
    let url: URL
    let modifiedAt: Date
    let fileSize: Int
}

struct CodexRolloutSummary {
    let sessionID: String?
    let cwd: String?
    let model: String?
    let lastLifecycleEvent: String?
    let lastLifecycleReason: String?
    let lastLifecycleAt: Date?
    let latestTokenRecord: (Date, CodexTokenInfo, CodexRateLimits?)?
    /// Every rate-limit report in the file, not just the last one: a rollout can
    /// carry several quota families, and keeping only the newest would hide the
    /// one actually constraining the account.
    let quotaReports: [(Date, CodexRateLimits)]
    let cacheEvidence: CacheEvidenceAccumulator
}

struct CachedRolloutSummary {
    let modifiedAt: Date
    let fileSize: Int
    // nil records that the file decoded to no usable records, so an unchanged
    // file is not re-read just to fail again.
    let summary: CodexRolloutSummary?
}

struct ParsedRollout {
    let session: AgentSession?
    let usage: [MeasuredUsage]
    let modifiedAt: Date
}

struct MeasuredUsage {
    let windows: [UsageWindow]
    let measuredAt: Date
}

struct CodexRolloutRecord: Decodable {
    let timestamp: String?
    let type: String
    let payload: Payload?

    struct Payload: Decodable {
        let id: String?
        let cwd: String?
        let model: String?
        let type: String?
        let info: CodexTokenInfo?
        let rateLimits: CodexRateLimits?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case id, cwd, model, type, info, reason
            case rateLimits = "rate_limits"
        }
    }
}

struct CodexTokenInfo: Decodable {
    let lastTokenUsage: CodexTokenUsage?

    enum CodingKeys: String, CodingKey {
        case lastTokenUsage = "last_token_usage"
    }
}

struct CodexTokenUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct CodexRateLimits: Decodable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}
