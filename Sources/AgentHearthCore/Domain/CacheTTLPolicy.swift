import Foundation

/// The prompt-cache lifetime AgentHearth assumes when a provider does not
/// serialize the request's explicit cache policy. GPT-5.6 uses OpenAI's
/// documented 30-minute policy; every other model keeps a conservative
/// five-minute fallback and should remain marked as inferred.
public enum CacheTTLPolicy {
    /// Conservative fallback for models without a documented cache lifetime.
    public static let fallbackTTLSeconds = 5 * 60

    /// OpenAI's documented prompt-cache lifetime for GPT-5.6.
    public static let documentedOpenAITTLSeconds = 30 * 60

    /// The OpenAI model identifier whose cache lifetime is documented.
    public static let documentedOpenAIModelID = "gpt-5.6"

    /// Whether the model name identifies an OpenAI model whose cache lifetime
    /// is documented rather than inferred.
    public static func hasDocumentedTTL(openAIModel model: String?) -> Bool {
        model?.lowercased().contains(documentedOpenAIModelID) == true
    }

    /// TTL for telemetry known to come from OpenAI (Codex rollouts).
    public static func ttlSeconds(openAIModel model: String?) -> Int {
        hasDocumentedTTL(openAIModel: model) ? documentedOpenAITTLSeconds : fallbackTTLSeconds
    }

    /// TTL for telemetry that names its provider (OpenCode messages). The
    /// documented lifetime only applies when the provider actually is OpenAI.
    public static func ttlSeconds(provider: String?, model: String?) -> Int {
        provider?.lowercased() == "openai" && hasDocumentedTTL(openAIModel: model)
            ? documentedOpenAITTLSeconds
            : fallbackTTLSeconds
    }
}
