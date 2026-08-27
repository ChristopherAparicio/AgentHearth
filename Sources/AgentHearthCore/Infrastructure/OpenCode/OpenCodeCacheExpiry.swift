import AgentHearthApplication
import AgentHearthDomain
import Foundation

/// Cache lifetime inferred from the latest assistant turn, shared by the two
/// OpenCode readers (local SQLite and the HTTP server API). Only this expiry
/// math is shared: the readers intentionally differ in status derivation and
/// cache-health evidence policy (see their doc comments).
struct OpenCodeCacheExpiry {
    let ttlSeconds: Int
    let remainingSeconds: Int?
    let temperature: CacheTemperature

    init(provider: String?, model: String?, confirmedAt: Date?, now: Date) {
        let ttl = CacheTTLPolicy.ttlSeconds(provider: provider, model: model)
        let remaining = confirmedAt.map { max(0, ttl - max(0, Int(now.timeIntervalSince($0)))) }
        ttlSeconds = ttl
        remainingSeconds = remaining
        temperature = if let remaining {
            remaining == 0 ? .cold : remaining <= 60 ? .expiring : .warm
        } else {
            .unknown
        }
    }
}
