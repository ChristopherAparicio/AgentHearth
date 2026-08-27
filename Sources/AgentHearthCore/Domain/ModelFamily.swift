import Foundation

/// The provider family behind a model identifier, classified by substring so
/// unknown future identifiers still land in the right bucket ("claude-4-6",
/// "gpt-5.2-codex", "o4-mini", ...).
///
/// Classification rules, in order:
/// 1. An identifier containing "claude" is `.anthropic`.
/// 2. Otherwise, one containing "gpt", "o1", "o3", or "o4" is `.openAI`.
/// 3. Everything else — including a missing identifier — is `.other`.
///
/// Matching is case-insensitive on the whole identifier, so "o1" also matches
/// identifiers that merely contain that fragment. That looseness is
/// deliberate: it mirrors how provider CLIs abbreviate model names.
public enum ModelFamily: String, Codable, Sendable {
    case anthropic
    case openAI
    case other

    public init(modelID: String?) {
        let normalized = modelID?.lowercased() ?? ""
        if normalized.contains("claude") {
            self = .anthropic
        } else if normalized.contains("gpt") || normalized.contains("o1")
            || normalized.contains("o3") || normalized.contains("o4") {
            self = .openAI
        } else {
            self = .other
        }
    }
}
