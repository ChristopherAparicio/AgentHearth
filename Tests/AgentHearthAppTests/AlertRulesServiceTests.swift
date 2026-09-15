import AgentHearthCore
import Foundation
import XCTest

@MainActor
final class AlertRulesServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var service: AlertRulesService!

    override func setUp() async throws {
        suiteName = "AlertRulesServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        service = AlertRulesService(preferences: PreferencesStore(defaults: defaults))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testAProviderNotifiesUntilItIsTurnedOff() {
        XCTAssertTrue(service.cacheNotificationsEnabled(for: .claudeCode))

        service.setCacheNotificationsEnabled(false, for: .claudeCode)

        XCTAssertFalse(service.cacheNotificationsEnabled(for: .claudeCode))
        XCTAssertTrue(service.cacheNotificationsEnabled(for: .codex), "the rule is per provider")
    }

    func testTheMasterSwitchOverridesEveryProviderRule() {
        service.setCacheNotificationsEnabled(true, for: .claudeCode)

        service.preferences.cacheExpiryEnabled = false

        XCTAssertFalse(service.cacheNotificationsEnabled(for: .claudeCode))
    }

    func testFlippingAProviderTwiceLeavesOneRuleBehind() {
        service.setCacheNotificationsEnabled(false, for: .codex)
        service.setCacheNotificationsEnabled(true, for: .codex)
        service.setCacheNotificationsEnabled(false, for: .codex)

        let codexRules = service.preferences.cacheNotificationRules
            .filter { $0.scope == .provider && $0.providerID == .codex }
        XCTAssertEqual(codexRules.count, 1, "rules must be replaced, not appended")
        XCTAssertFalse(service.cacheNotificationsEnabled(for: .codex))
    }

    func testRulesOutliveTheServiceThatWroteThem() {
        service.setCacheNotificationsEnabled(false, for: .openCode)

        let reloaded = AlertRulesService(preferences: PreferencesStore(defaults: defaults))

        XCTAssertFalse(reloaded.cacheNotificationsEnabled(for: .openCode))
    }

    func testAProfileFallsBackToTheGlobalWarningUntilItIsGivenItsOwn() {
        service.preferences.cacheWarningSeconds = 120
        XCTAssertEqual(service.cacheNotificationWarningSeconds(.codex), 120)

        service.setCacheNotificationProfile(.codex, warningSeconds: 300)

        XCTAssertEqual(service.cacheNotificationWarningSeconds(.codex), 300)
        XCTAssertEqual(service.cacheNotificationWarningSeconds(.claudeCode), 120)
    }

    func testTheDefaultProfilesAreOfferedWithoutAnySessionObserved() {
        XCTAssertEqual(service.cacheNotificationProfiles, [.codex, .claudeCode])
    }
}
