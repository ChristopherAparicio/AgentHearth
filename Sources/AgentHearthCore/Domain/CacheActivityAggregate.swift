import Foundation

/// A rollup of cache activity over some slice of history: a day, a session,
/// a project, or the whole dashboard window. Conforming types supply the raw
/// counters; the derived rates are defined once here so every slice reports
/// them identically.
public protocol CacheActivityAggregate {
    /// Total input tokens observed, cached and uncached alike.
    var inputTokens: Int { get }
    /// Input tokens read back from the provider cache.
    var cachedInputTokens: Int { get }
    /// Turns (requests) observed in this slice.
    var turnCount: Int { get }
    /// Turns that hit the provider cache.
    var hitCount: Int { get }
    /// Total output tokens produced.
    var outputTokens: Int { get }
}

extension CacheActivityAggregate {
    public var uncachedInputTokens: Int { max(0, inputTokens - cachedInputTokens) }

    /// Fraction of input tokens served from cache, or nil with no input.
    public var cacheReuseRate: Double? {
        inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : nil
    }

    /// Fraction of turns that hit the cache, or nil with no turns.
    public var hitRate: Double? {
        turnCount > 0 ? Double(hitCount) / Double(turnCount) : nil
    }

    /// Tokens that plausibly counted against a usage window: everything the
    /// provider processed or generated at full price. Cached reads are
    /// excluded because they are far cheaper, and including them would rank a
    /// large warm session above a smaller one reprocessing its whole context
    /// on every turn — the opposite of what a consumption ranking is for.
    public var billableTokens: Int { uncachedInputTokens + max(0, outputTokens) }
}
