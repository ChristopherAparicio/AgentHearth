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
    /// Starts the provider's CLI in a fresh terminal with no session to resume,
    /// e.g. so Claude Code refreshes its sign-in on launch.
    func openProviderCLI(_ providerID: AgentProviderID) async throws
}

public extension SessionOpening {
    func openProviderCLI(_ providerID: AgentProviderID) async throws {
        throw SessionOpeningUnsupportedError(providerID: providerID)
    }
}

public struct SessionOpeningUnsupportedError: LocalizedError {
    public let providerID: AgentProviderID
    public var errorDescription: String? { "Launching \(providerID.rawValue) is not supported here" }
}
