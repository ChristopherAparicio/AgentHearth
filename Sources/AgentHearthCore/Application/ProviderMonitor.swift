import AgentHearthDomain
import Foundation

public actor ProviderMonitor {
    private let primaryConnectors: [any ProviderConnector]
    private var additionalConnectors: [any ProviderConnector] = []
    private var sourceModes: [AgentProviderID: ProviderDataSourceMode] = [:]

    public init(connectors: [any ProviderConnector]) {
        self.primaryConnectors = connectors
    }

    private var connectors: [any ProviderConnector] {
        primaryConnectors + additionalConnectors
    }

    public func setAdditionalConnectors(_ connectors: [any ProviderConnector]) async {
        additionalConnectors = connectors
        await withTaskGroup(of: Void.self) { group in
            for connector in connectors {
                let mode = sourceModes[connector.providerID] ?? .automatic
                group.addTask { await connector.setSourceMode(mode) }
            }
        }
    }

    /// Forwards authoritative account usage to every connector able to use it.
    public func ingestAccountUsage(_ usage: AccountUsage?) async {
        for connector in connectors {
            if let ingesting = connector as? any AccountUsageIngesting {
                await ingesting.ingestAccountUsage(usage)
            }
        }
    }

    public func setSourceMode(_ mode: ProviderDataSourceMode, for providerID: AgentProviderID) async {
        sourceModes[providerID] = mode
        await withTaskGroup(of: Void.self) { group in
            for connector in connectors where connector.providerID == providerID {
                group.addTask { await connector.setSourceMode(mode) }
            }
        }
    }

    public func setSourceModes(_ modes: [AgentProviderID: ProviderDataSourceMode]) async {
        sourceModes = modes
        await withTaskGroup(of: Void.self) { group in
            for connector in connectors {
                let mode = modes[connector.providerID] ?? .automatic
                group.addTask {
                    await connector.setSourceMode(mode)
                }
            }
        }
    }

    public func collect() async -> [ProviderSnapshot] {
        await withTaskGroup(of: ProviderSnapshot.self, returning: [ProviderSnapshot].self) { group in
            for connector in connectors {
                group.addTask {
                    do {
                        return try await connector.snapshot()
                    } catch {
                        return ProviderSnapshot(
                            id: connector.providerID,
                            connectionState: .degraded(message: error.localizedDescription),
                            sessions: [],
                            usageWindows: []
                        )
                    }
                }
            }

            var snapshots: [ProviderSnapshot] = []
            for await snapshot in group {
                snapshots.append(snapshot)
            }
            return Dictionary(grouping: snapshots, by: \ProviderSnapshot.id)
                .map { providerID, values in Self.merge(providerID, values) }
                .sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }

    private static func merge(
        _ providerID: AgentProviderID,
        _ snapshots: [ProviderSnapshot]
    ) -> ProviderSnapshot {
        let sessions = Dictionary(
            snapshots.flatMap(\.sessions).map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.lastActivityAt >= second.lastActivityAt ? first : second
            }
        ).values.sortedWorkingFirst()
        let windows = Dictionary(
            snapshots.flatMap(\.usageWindows).map { ($0.id, $0) },
            uniquingKeysWith: { first, second in
                first.measuredAt >= second.measuredAt ? first : second
            }
        ).values.sorted { $0.label < $1.label }
        let connectionState: ProviderConnectionState
        if snapshots.contains(where: { $0.connectionState == .connected }) {
            connectionState = .connected
        } else if let degraded = snapshots.compactMap({ snapshot -> String? in
            if case let .degraded(message) = snapshot.connectionState { return message }
            return nil
        }).first {
            connectionState = .degraded(message: degraded)
        } else {
            connectionState = .unavailable
        }
        return ProviderSnapshot(
            id: providerID,
            connectionState: connectionState,
            sessions: Array(sessions),
            usageWindows: Array(windows),
            updatedAt: snapshots.map(\.updatedAt).max() ?? .now
        )
    }
}
