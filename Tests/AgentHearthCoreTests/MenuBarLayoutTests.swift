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

    /// The layout-level flame guard reasons about the *configured* items, so a
    /// non-empty layout switches it off — yet those items can still render to
    /// nothing, leaving the status item with no content at all. An empty status
    /// item has zero width, and macOS removes a zero-width item, which for a
    /// MenuBarExtra app terminates the process. Whoever draws the label must
    /// therefore fall back to the flame on the rendered items, not this flag.
    func testANonEmptyLayoutCanStillRenderNothing() {
        let layout = MenuBarLayout(showsFlame: false, items: [
            MenuBarItem(metric: .sessionCount(.working), scope: .provider(.openCode), hidesWhenZero: true),
        ])
        XCTAssertFalse(layout.effectiveShowsFlame, "the layout believes its items will draw something")

        // OpenCode has no working session, and the item hides at zero.
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 60)
        XCTAssertTrue(rendered.isEmpty, "so nothing is left to draw, and the flag cannot know")

        // The same layout with no snapshots at all -- the state at launch,
        // before the first poll returns.
        let atLaunch = MenuBarLayoutRenderer.render(layout, snapshots: [], cacheWarningSeconds: 60)
        XCTAssertTrue(atLaunch.isEmpty)
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
            MenuBarItem(metric: .warmCaches),
            MenuBarItem(metric: .warmCaches, scope: .provider(.claudeCode)),
            MenuBarItem(metric: .cacheReuse, scope: .provider(.openCode)),
        ])
        let rendered = MenuBarLayoutRenderer.render(layout, snapshots: snapshots, cacheWarningSeconds: 300)
        // Codex sessions report 0.9 and 0.5 reuse; both caches are warm and one
        // has 120 s left. Claude sessions have no cache reading. OpenCode has
        // no session, so its reuse item is skipped.
        XCTAssertEqual(rendered.map(\.text), ["70%", "1", "2", "0"])
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
