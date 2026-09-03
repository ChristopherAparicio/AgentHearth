import XCTest
@testable import AgentHearthApplication
@testable import AgentHearthDomain
@testable import AgentHearthInfrastructure

final class NotificationPolicyTests: XCTestCase {
    func testNightModeSilencesOrdinaryAlerts() {
        let policy = NotificationPolicy(
            soundsEnabled: true,
            silenceSoundsInNightMode: true,
            allowCriticalSoundsInNightMode: true
        )

        XCTAssertFalse(policy.shouldPlaySound(for: .warning, smartSleepMode: .night))
        XCTAssertTrue(policy.shouldPlaySound(for: .critical, smartSleepMode: .night))
        XCTAssertTrue(policy.shouldPlaySound(for: .warning, smartSleepMode: .keepAwake))
    }

    func testGlobalSoundSettingAlwaysWins() {
        let policy = NotificationPolicy(soundsEnabled: false)

        XCTAssertFalse(policy.shouldPlaySound(for: .critical, smartSleepMode: .off))
        XCTAssertFalse(policy.shouldPlaySound(for: .critical, smartSleepMode: .night))
    }

    func testCacheNotificationScopesPreferSessionThenProjectThenProvider() {
        let session = AgentSession(
            id: "session-1",
            providerID: .codex,
            title: "Test session",
            projectName: "AgentHearth",
            status: .working,
            lastActivityAt: .now,
            cache: CacheSnapshot(temperature: .warm, lastConfirmedAt: .now),
            host: AgentHost(id: "rtx", displayName: "RTX", kind: .ssh)
        )
        var preferences = AlertPreferences()

        preferences.setCacheNotificationRule(enabled: false, scope: .provider, for: session)
        XCTAssertFalse(preferences.cacheNotificationsEnabled(for: session))

        preferences.setCacheNotificationRule(enabled: true, scope: .project, for: session)
        XCTAssertTrue(preferences.cacheNotificationsEnabled(for: session))

        preferences.setCacheNotificationRule(enabled: false, scope: .session, for: session)
        XCTAssertFalse(preferences.cacheNotificationsEnabled(for: session))
    }

    func testIgnoredCacheDoesNotNotifyButAcknowledgedCacheKeepsPolicyEnabled() {
        let confirmedAt = Date(timeIntervalSince1970: 1_000)
        let session = AgentSession(
            id: "session-1",
            providerID: .codex,
            title: "Test session",
            status: .working,
            lastActivityAt: confirmedAt,
            cache: CacheSnapshot(temperature: .expiring, lastConfirmedAt: confirmedAt)
        )
        var preferences = AlertPreferences()

        preferences.setCacheAlertDisposition(.acknowledged, for: session)
        XCTAssertTrue(preferences.shouldNotifyCacheExpiry(for: session))

        preferences.setCacheAlertDisposition(.ignoredForCurrentCache, for: session)
        XCTAssertFalse(preferences.shouldNotifyCacheExpiry(for: session))
    }

    func testOpenCodeUsesTheUnderlyingModelForItsCacheProfile() {
        let session = AgentSession(
            id: "openai-session",
            providerID: .openCode,
            title: "OpenCode session",
            model: "gpt-5.6-sol",
            status: .working,
            lastActivityAt: .now,
            cache: CacheSnapshot(temperature: .warm, lastConfirmedAt: .now)
        )
        var preferences = AlertPreferences()

        preferences.setCacheNotificationProfile(.openCodeOpenAI, isEnabled: false, warningSeconds: 300)

        XCTAssertEqual(CacheNotificationProfile(session: session), .openCodeOpenAI)
        XCTAssertFalse(preferences.cacheNotificationsEnabled(for: session))
        XCTAssertEqual(preferences.cacheWarningSeconds(for: session), 300)
    }
}
