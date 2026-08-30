import AgentHearthApplication
import AgentHearthDomain
import Foundation

extension ClaudeCodeConnector {
    /// Session-wide token totals are accumulated so reuse reflects every turn,
    /// not just the last. A cold start contributes a large creation with zero
    /// read, dragging the aggregate down — which is what the user actually
    /// wants to see. The TTL a turn establishes for the next eligibility gap
    /// comes from the observed cache-creation bucket.
    static func evidenceObservation(
        for observation: ClaudeUsageObservation
    ) -> CacheEvidenceAccumulator.TurnObservation {
        let usage = observation.usage
        let cached = usage.cacheReadInputTokens ?? 0
        let fresh = usage.inputTokens ?? 0
        let created = usage.cacheCreationInputTokens ?? 0
        let ttl: TimeInterval = usage.cacheCreation?.ephemeral1hInputTokens ?? 0 > 0 ? 3_600 : 300
        return CacheEvidenceAccumulator.TurnObservation(
            timestamp: observation.timestamp,
            cachedReadTokens: cached,
            promptTokens: max(0, fresh) + max(0, cached) + max(0, created),
            ttl: ttl
        )
    }

    static func parseDate(_ value: String) -> Date? {
        ISO8601Instant.parse(value)
    }

    static func sanitizedTitle(_ value: String) -> String? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(120))
    }
}

struct ClaudeTranscriptCandidate {
    let url: URL
    let modifiedAt: Date
    let fileSize: Int
}

struct ClaudeTranscriptSummary {
    let sessionID: String
    let cwd: String?
    let title: String?
    let model: String?
    let latestUserAt: Date?
    let latestAssistantAt: Date?
    let latestTurnEndedAt: Date?
    let latestUsage: ClaudeUsageObservation?
    let evidence: CacheEvidenceAccumulator
}

struct CachedTranscriptSummary {
    let modifiedAt: Date
    let fileSize: Int
    // nil records that the file decoded to no usable records, so an unchanged
    // file is not re-read just to fail again.
    let summary: ClaudeTranscriptSummary?
}

struct CachedPlanUsage {
    let modifiedAt: Date
    let fileSize: Int
    let sample: PlanUsageSample?
}

struct ClaudeUsageObservation {
    let timestamp: Date
    let usage: ClaudeTranscriptRecord.Message.Usage
}

struct ClaudeTranscriptRecord: Decodable {
    let type: String
    let subtype: String?
    let timestamp: String?
    let sessionID: String?
    let cwd: String?
    let aiTitle: String?
    let requestID: String?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, subtype, timestamp, cwd, aiTitle, message
        case sessionID = "sessionId"
        case requestID = "requestId"
    }

    struct Message: Decodable {
        let id: String?
        let model: String?
        let stopReason: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case id, model, usage
            case stopReason = "stop_reason"
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
            }

            struct CacheCreation: Decodable {
                let ephemeral1hInputTokens: Int?
                let ephemeral5mInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
                    case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
                }
            }
        }
    }
}
