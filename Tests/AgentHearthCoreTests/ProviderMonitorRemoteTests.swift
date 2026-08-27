import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class ProviderMonitorRemoteTests: XCTestCase {
    func testMergesLocalAndRemoteConnectorsWithoutSessionCollisions() async {
        let local = ProviderSnapshot(
            id: .codex,
            connectionState: .connected,
            sessions: [session(id: "same", host: .local)],
            usageWindows: []
        )
        let remoteHost = AgentHost(
            id: "rtx",
            displayName: "RTX",
            kind: .ssh,
            sshDestination: "rtx-server"
        )
        let remote = ProviderSnapshot(
            id: .codex,
            connectionState: .connected,
            sessions: [session(id: "rtx:codex:same", host: remoteHost)],
            usageWindows: []
        )
        let monitor = ProviderMonitor(connectors: [SnapshotConnector(snapshot: local)])
        await monitor.setAdditionalConnectors([SnapshotConnector(snapshot: remote)])

        let snapshots = await monitor.collect()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.sessions.count, 2)
        XCTAssertEqual(Set(snapshots.first?.sessions.map(\.host.id) ?? []), Set(["local", "rtx"]))
    }

    private func session(id: String, host: AgentHost) -> AgentSession {
        AgentSession(
            id: id,
            providerID: .codex,
            title: id,
            status: .working,
            lastActivityAt: .now,
            host: host
        )
    }
}

private actor SnapshotConnector: ProviderConnector {
    nonisolated let providerID = AgentProviderID.codex
    let value: ProviderSnapshot

    init(snapshot: ProviderSnapshot) {
        self.value = snapshot
    }

    func setSourceMode(_ mode: ProviderDataSourceMode) {}
    func snapshot() -> ProviderSnapshot { value }
}
