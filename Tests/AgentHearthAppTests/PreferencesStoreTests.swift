import AgentHearthCore
import Foundation
import XCTest

@MainActor
final class PreferencesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: PreferencesStore!

    /// A suite of its own per test, torn down after it, so nothing leaks into
    /// the machine's real preferences or into the next test. `async` so the
    /// hooks run on the actor the test class is isolated to.
    override func setUp() async throws {
        suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = PreferencesStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The regression this target was created by: the picker offered 7 days
    /// while the getter only accepted 15 min / 1 h / 4 h / 1 day, so choosing
    /// "7 j" silently read back as "1 h" on the next launch.
    func testEveryRangeThePickerOffersSurvivesARestart() {
        for minutes in PreferencesStore.consumptionRangePresets {
            store.consumptionRangeMinutes = minutes
            XCTAssertEqual(
                PreferencesStore(defaults: defaults).consumptionRangeMinutes,
                minutes,
                "the consumption picker offers \(minutes) min but it is not read back"
            )
        }
    }

    func testAnUnknownConsumptionRangeFallsBackToAnHour() {
        defaults.set(240, forKey: "consumptionRangeMinutes")
        XCTAssertEqual(store.consumptionRangeMinutes, 60)
    }

    func testCacheInsightsKeepsWhicheverRangeItWasGiven() {
        for minutes in [60, 1_440, 10_080, 43_200] {
            store.historyRangeMinutes = minutes
            XCTAssertEqual(PreferencesStore(defaults: defaults).historyRangeMinutes, minutes)
        }
    }

    func testTheHistoryRangeDefaultsToADayRatherThanAMinute() {
        // The key holds minutes; an absent value must not read as zero.
        XCTAssertEqual(store.historyRangeMinutes, 1_440)
    }

    func testAMalformedMaximumIsReadBackAsTheDocumentedDefault() {
        defaults.set(37, forKey: "maximumVisibleSessions")
        XCTAssertEqual(store.maximumVisibleSessions, 20)
        store.maximumVisibleSessions = 50
        XCTAssertEqual(store.maximumVisibleSessions, 50)
    }

    func testAMalformedCacheThresholdIsReadBackAsTheDocumentedDefault() {
        defaults.set(83, forKey: "cacheHitThreshold")
        XCTAssertEqual(store.cacheHitThreshold, 80)
    }

    func testARecapWindowIsAlwaysAtLeastAnHourLong() {
        store.morningRecapStartHour = 9
        store.morningRecapEndHour = 9
        XCTAssertGreaterThan(store.morningRecapEndHour, store.morningRecapStartHour)
    }

    func testAnOutOfRangeRecapStartIsReadBackAsSeven() {
        defaults.set(23, forKey: "morningRecapStartHour")
        XCTAssertEqual(store.morningRecapStartHour, 7)
    }

    func testRemovedDailyCadencesAreReadAsTheirClosestSurvivor() {
        defaults.set("daily", forKey: "historyReportCadence")
        XCTAssertEqual(store.historyReportCadence, .off)
        defaults.set("dailyAndWeekly", forKey: "historyReportCadence")
        XCTAssertEqual(store.historyReportCadence, .weekly)
        defaults.set("weekly", forKey: "historyReportCadence")
        XCTAssertEqual(store.historyReportCadence, .weekly)
    }

    func testMidnightIsAValidReportHour() {
        store.historyReportHour = 0
        XCTAssertEqual(store.historyReportHour, 0, "0 must not be mistaken for an absent value")
    }

    func testAnUnknownProviderInStorageIsIgnoredRatherThanCrashing() {
        defaults.set(["claudeCode", "chatgpt-2"], forKey: "hiddenProviders")
        XCTAssertEqual(store.hiddenProviders, [.claudeCode])
    }

    func testEveryProviderGetsADataSourceModeEvenWhenNothingIsStored() {
        XCTAssertEqual(store.dataSourceModes.count, AgentProviderID.allCases.count)
        XCTAssertTrue(store.dataSourceModes.values.allSatisfy { $0 == .automatic })
    }

    func testSmartSleepModeIsAbsentUntilItIsFirstChosen() {
        XCTAssertNil(store.smartSleepMode)
        store.smartSleepMode = .keepAwake
        XCTAssertEqual(PreferencesStore(defaults: defaults).smartSleepMode, .keepAwake)
    }

    /// A fresh install gets the flame; an upgrade keeps the menu bar it had.
    func testALegacyDisplayModeIsMigratedIntoALayout() {
        XCTAssertEqual(store.menuBarLayout, .default)

        defaults.set("sessionCounts", forKey: "menuBarDisplayMode")
        let migrated = PreferencesStore(defaults: defaults).menuBarLayout
        XCTAssertEqual(migrated.items.count, 2)
        XCTAssertTrue(migrated.showsFlame)

        // Once a layout of its own is stored, the legacy key stops mattering.
        store.menuBarLayout = MenuBarLayout(showsFlame: false, items: [
            MenuBarItem(metric: .cacheReuse),
        ])
        XCTAssertEqual(PreferencesStore(defaults: defaults).menuBarLayout.items.count, 1)
    }
}
