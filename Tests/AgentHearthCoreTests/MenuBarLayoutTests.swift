import Foundation
import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class MenuBarLayoutTests: XCTestCase {
    func testDefaultLayoutIsTheFlameAlone() {
        let layout = MenuBarLayout.default
        XCTAssertTrue(layout.items.isEmpty)
        XCTAssertTrue(layout.effectiveShowsFlame)
        XCTAssertTrue(MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 60).isEmpty)
    }

    func testFlameCannotBeHiddenWithoutItems() {
        var layout = MenuBarLayout(showsFlame: false, items: [])
        XCTAssertTrue(layout.effectiveShowsFlame)
        layout.items = [MenuBarItem(metric: .sessionCount(.all))]
        XCTAssertFalse(layout.effectiveShowsFlame)
    }

    func testSessionCountsHonorScopeAndFilter() {
        let layout = MenuBarLayout(items: [
            MenuBarItem(metric: .sessionCount(.all)),
            MenuBarItem(metric: .sessionCount(.working), scope: .provider(.codex)),
            MenuBarItem(metric: .sessionCount(.attention), scope: .provider(.claudeCode)),
            MenuBarItem(metric: .sessionCount(.working), scope: .provider(.openCode)),
        ])
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 60)
        XCTAssertEqual(rendered.map(\.text), ["4", "1", "1", "0"])
    }

    func testHidesWhenZeroSkipsTheItem() {
        let layout = MenuBarLayout(items: [
            MenuBarItem(metric: .sessionCount(.working), scope: .provider(.openCode), hidesWhenZero: true),
            MenuBarItem(metric: .sessionCount(.working), scope: .provider(.codex), hidesWhenZero: true),
        ])
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 60)
        XCTAssertEqual(rendered.map(\.text), ["1"])
    }

    func testUsageWindowPinsOneWindowOrTakesTheHighest() {
        let layout = MenuBarLayout(items: [
            MenuBarItem(metric: .usageWindow(windowID: "codex-10080"), scope: .provider(.codex)),
            MenuBarItem(metric: .usageWindow(windowID: nil), scope: .provider(.claudeCode)),
            MenuBarItem(metric: .usageWindow(windowID: nil)),
            MenuBarItem(metric: .usageWindow(windowID: "missing"), scope: .provider(.codex)),
        ])
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 60)
        // The missing window is skipped rather than shown as 0.
        XCTAssertEqual(rendered.map(\.text), ["42%", "67%", "67%"])
    }

    func testCacheReuseAndExpiringCaches() {
        let layout = MenuBarLayout(items: [
            MenuBarItem(metric: .cacheReuse, scope: .provider(.codex)),
            MenuBarItem(metric: .expiringCaches),
            MenuBarItem(metric: .cacheReuse, scope: .provider(.openCode)),
        ])
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 300)
        // Codex sessions report 0.9 and 0.5 reuse; one warm cache has 120 s left.
        // OpenCode has no session, so its reuse item is skipped.
        XCTAssertEqual(rendered.map(\.text), ["70%", "1"])
    }

    func testPrefixesResolveAgainstTheScope() {
        let layout = MenuBarLayout(items: [
            MenuBarItem(metric: .sessionCount(.all), scope: .provider(.codex), tint: .orange, prefix: .providerSymbol),
            MenuBarItem(metric: .sessionCount(.all), prefix: .providerSymbol),
            MenuBarItem(metric: .sessionCount(.all), prefix: .text("  CC ")),
            MenuBarItem(metric: .sessionCount(.all), prefix: .text("   ")),
        ])
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 60)
        XCTAssertEqual(rendered[0].providerSymbol, .codex)
        XCTAssertEqual(rendered[0].tint, .orange)
        XCTAssertNil(rendered[1].providerSymbol, "no single provider to draw for the all-providers scope")
        XCTAssertEqual(rendered[2].prefixText, "CC")
        XCTAssertNil(rendered[3].prefixText)
    }

    func testLayoutRoundTripsThroughCodable() throws {
        let layout = MenuBarLayout(showsFlame: false, items: [
            MenuBarItem(metric: .usageWindow(windowID: "codex-10080"), scope: .provider(.codex), tint: .purple, prefix: .text("OA"), hidesWhenZero: true),
            MenuBarItem(metric: .sessionCount(.attention), prefix: .providerSymbol),
            MenuBarItem(metric: .usageWindow(windowID: nil)),
            MenuBarItem(metric: .expiringCaches, tint: .red),
        ])
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)
        XCTAssertEqual(decoded, layout)
    }

    // MARK: - Fixtures

    private var snapshots: [ProviderSnapshot] {
        [
            ProviderSnapshot(
                id: .codex,
                connectionState: .connected,
                sessions: [
                    session("c1", provider: .codex, status: .working, reuse: 0.9, remaining: 120),
                    session("c2", provider: .codex, status: .idle, reuse: 0.5, remaining: 1_500),
                ],
                usageWindows: [
                    UsageWindow(id: "codex-300", label: "5 hours", usedFraction: 0.10),
                    UsageWindow(id: "codex-10080", label: "7 days", usedFraction: 0.42),
                ]
            ),
            ProviderSnapshot(
                id: .claudeCode,
                connectionState: .connected,
                sessions: [
                    session("a1", provider: .claudeCode, status: .waitingForApproval, reuse: nil, remaining: nil),
                    session("a2", provider: .claudeCode, status: .completed, reuse: nil, remaining: nil),
                ],
                usageWindows: [
                    UsageWindow(id: "claude-5h", label: "5 hours", usedFraction: 0.20),
                    UsageWindow(id: "claude-7d", label: "7 days", usedFraction: 0.67),
                ]
            ),
            ProviderSnapshot(id: .openCode, connectionState: .connected, sessions: [], usageWindows: []),
        ]
    }

    private func session(
        _ id: String,
        provider: AgentProviderID,
        status: SessionStatus,
        reuse: Double?,
        remaining: Int?
    ) -> AgentSession {
        AgentSession(
            id: id,
            providerID: provider,
            title: id,
            status: status,
            lastActivityAt: .now,
            // `inputTokens` is the fresh part only, so fresh + cached = 1000
            // makes the reuse rate exactly `reuse`.
            cache: CacheSnapshot(
                temperature: remaining == nil ? .unknown : .warm,
                remainingSeconds: remaining,
                ttlSeconds: 1_800,
                inputTokens: reuse.map { Int((1 - $0) * 1_000) },
                cachedReadTokens: reuse.map { Int($0 * 1_000) }
            ),
            target: SessionTarget(providerID: provider, sessionID: id)
        )
    }
}
