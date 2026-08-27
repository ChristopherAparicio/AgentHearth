import AgentHearthDomain
import Foundation

public protocol ProviderConnector: Sendable {
    var providerID: AgentProviderID { get }
    func setSourceMode(_ mode: ProviderDataSourceMode) async
    func snapshot() async throws -> ProviderSnapshot
}

/// Optional capability for connectors whose collector can replay cache events
/// observed while the macOS app was offline.
public protocol ProviderHistoryConnector: Sendable {
    func pendingHistoryEvents() async throws -> [CacheHistoryImportEvent]
}

/// Optional capability for connectors that can enrich their snapshots with
/// authoritative account usage fetched from the provider's own service.
public protocol AccountUsageIngesting: Sendable {
    func ingestAccountUsage(_ usage: AccountUsage?) async
}

public protocol SessionOpening: Sendable {
    func open(_ target: SessionTarget, destination: SessionOpenDestination) async throws
}
