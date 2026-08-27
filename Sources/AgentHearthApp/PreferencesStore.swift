import AgentHearthCore
import Foundation

/// The single owner of AgentHearth's persisted preferences. Every accessor
/// keeps the exact `UserDefaults` key and encoding used by earlier releases,
/// and getters validate stored values back to the documented defaults so the
/// rest of the app only ever sees well-formed preferences.
@MainActor
final class PreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var notificationPolicy: NotificationPolicy {
        get { decode(NotificationPolicy.self, forKey: PreferenceKey.notificationPolicy) ?? NotificationPolicy() }
        set { encode(newValue, forKey: PreferenceKey.notificationPolicy) }
    }

    var alertPreferences: AlertPreferences {
        get { decode(AlertPreferences.self, forKey: PreferenceKey.alertPreferences) ?? AlertPreferences() }
        set { encode(newValue, forKey: PreferenceKey.alertPreferences) }
    }

    var sessionFocusPreferences: SessionFocusPreferences {
        get { decode(SessionFocusPreferences.self, forKey: PreferenceKey.sessionFocusPreferences) ?? SessionFocusPreferences() }
        set { encode(newValue, forKey: PreferenceKey.sessionFocusPreferences) }
    }

    var sessionOpenPreferences: SessionOpenPreferences {
        get { decode(SessionOpenPreferences.self, forKey: PreferenceKey.sessionOpenPreferences) ?? SessionOpenPreferences() }
        set { encode(newValue, forKey: PreferenceKey.sessionOpenPreferences) }
    }

    var remoteHosts: [RemoteHostConfiguration] {
        get { decode([RemoteHostConfiguration].self, forKey: PreferenceKey.remoteHosts) ?? [] }
        set { encode(newValue, forKey: PreferenceKey.remoteHosts) }
    }

    var openCodeServers: [OpenCodeServerConfiguration] {
        get { decode([OpenCodeServerConfiguration].self, forKey: PreferenceKey.openCodeServers) ?? [] }
        set { encode(newValue, forKey: PreferenceKey.openCodeServers) }
    }

    var hiddenProviders: Set<AgentProviderID> {
        get {
            Set(
                (defaults.stringArray(forKey: PreferenceKey.hiddenProviders) ?? [])
                    .compactMap(AgentProviderID.init(rawValue:))
            )
        }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: PreferenceKey.hiddenProviders) }
    }

    var dataSourceModes: [AgentProviderID: ProviderDataSourceMode] {
        get {
            let stored = defaults.dictionary(forKey: PreferenceKey.dataSourceModes) as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: AgentProviderID.allCases.map { providerID in
                let mode = stored[providerID.rawValue].flatMap(ProviderDataSourceMode.init(rawValue:))
                    ?? .automatic
                return (providerID, mode)
            })
        }
        set {
            defaults.set(
                Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.rawValue) }),
                forKey: PreferenceKey.dataSourceModes
            )
        }
    }

    /// The persisted smart-sleep mode, absent until the user first enables it.
    var smartSleepMode: SmartSleepMode? {
        get { defaults.string(forKey: PreferenceKey.smartSleepMode).flatMap(SmartSleepMode.init(rawValue:)) }
        set {
            guard let newValue else { return }
            defaults.set(newValue.rawValue, forKey: PreferenceKey.smartSleepMode)
        }
    }

    var smartSleepScheduleMode: SmartSleepScheduleMode {
        get {
            defaults.string(forKey: PreferenceKey.smartSleepScheduleMode)
                .flatMap(SmartSleepScheduleMode.init(rawValue:)) ?? .unlimited
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.smartSleepScheduleMode) }
    }

    var smartSleepDurationMinutes: Int {
        get {
            let stored = defaults.integer(forKey: PreferenceKey.smartSleepDurationMinutes)
            return stored > 0 ? stored : 240
        }
        set { defaults.set(newValue, forKey: PreferenceKey.smartSleepDurationMinutes) }
    }

    var smartSleepTargetTime: Date {
        get {
            defaults.object(forKey: PreferenceKey.smartSleepTargetTime) as? Date
                ?? Self.defaultSmartSleepTargetTime()
        }
        set { defaults.set(newValue, forKey: PreferenceKey.smartSleepTargetTime) }
    }

    var smartSleepExpiresAt: Date? {
        get { defaults.object(forKey: PreferenceKey.smartSleepExpiresAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: PreferenceKey.smartSleepExpiresAt)
            } else {
                defaults.removeObject(forKey: PreferenceKey.smartSleepExpiresAt)
            }
        }
    }

    var sessionDisplayWindow: SessionDisplayWindow {
        get {
            defaults.string(forKey: PreferenceKey.sessionDisplayWindow)
                .flatMap { Int($0) }
                .flatMap(SessionDisplayWindow.init(rawValue:)) ?? .oneDay
        }
        set { defaults.set(String(newValue.rawValue), forKey: PreferenceKey.sessionDisplayWindow) }
    }

    var visibleSessionStatuses: Set<SessionStatus> {
        get {
            guard let stored = defaults.array(forKey: PreferenceKey.visibleSessionStatuses) as? [String] else {
                return Set(SessionStatus.allCases)
            }
            return Set(stored.compactMap(SessionStatus.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: PreferenceKey.visibleSessionStatuses) }
    }

    var maximumVisibleSessions: Int {
        get {
            let stored = defaults.integer(forKey: PreferenceKey.maximumVisibleSessions)
            return [5, 10, 20, 50].contains(stored) ? stored : 20
        }
        set { defaults.set(newValue, forKey: PreferenceKey.maximumVisibleSessions) }
    }

    var showsSessionCacheIcon: Bool {
        get { defaults.object(forKey: PreferenceKey.showsSessionCacheIcon) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.showsSessionCacheIcon) }
    }

    var showsSessionCacheCountdown: Bool {
        get { defaults.object(forKey: PreferenceKey.showsSessionCacheCountdown) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.showsSessionCacheCountdown) }
    }

    var showsSessionCacheHits: Bool {
        get { defaults.object(forKey: PreferenceKey.showsSessionCacheHits) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.showsSessionCacheHits) }
    }

    var cacheReuseDisplayMode: CacheReuseDisplayMode {
        get {
            defaults.string(forKey: PreferenceKey.cacheReuseDisplayMode)
                .flatMap(CacheReuseDisplayMode.init(rawValue:)) ?? .sessionGlobal
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.cacheReuseDisplayMode) }
    }

    var showsCompactSessionRows: Bool {
        get { defaults.object(forKey: PreferenceKey.showsCompactSessionRows) as? Bool ?? false }
        set { defaults.set(newValue, forKey: PreferenceKey.showsCompactSessionRows) }
    }

    var claudeAccountUsageEnabled: Bool {
        get { defaults.object(forKey: PreferenceKey.claudeAccountUsageEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: PreferenceKey.claudeAccountUsageEnabled) }
    }

    var historyEnabled: Bool {
        get { defaults.object(forKey: PreferenceKey.historyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: PreferenceKey.historyEnabled) }
    }

    var historyRetention: HistoryRetention {
        get { HistoryRetention(rawValue: defaults.integer(forKey: PreferenceKey.historyRetentionDays)) ?? .thirtyDays }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.historyRetentionDays) }
    }

    var historyRangeDays: Int {
        get {
            let stored = defaults.integer(forKey: PreferenceKey.historyRangeDays)
            return [1, 7, 30, 90].contains(stored) ? stored : 7
        }
        set { defaults.set(newValue, forKey: PreferenceKey.historyRangeDays) }
    }

    var cacheHitThreshold: Int {
        get {
            let stored = defaults.integer(forKey: PreferenceKey.cacheHitThreshold)
            return [50, 60, 70, 80, 90, 95].contains(stored) ? stored : 80
        }
        set { defaults.set(newValue, forKey: PreferenceKey.cacheHitThreshold) }
    }

    var morningRecapEnabled: Bool {
        get { defaults.object(forKey: PreferenceKey.morningRecapEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: PreferenceKey.morningRecapEnabled) }
    }

    var morningRecapStartHour: Int {
        get {
            let stored = defaults.integer(forKey: PreferenceKey.morningRecapStartHour)
            return (0...22).contains(stored) ? stored : 7
        }
        set { defaults.set(newValue, forKey: PreferenceKey.morningRecapStartHour) }
    }

    /// Validated against the start hour so the recap window is always at
    /// least one hour long.
    var morningRecapEndHour: Int {
        get {
            let stored = defaults.integer(forKey: PreferenceKey.morningRecapEndHour)
            return (1...23).contains(stored) && stored > morningRecapStartHour ? stored : 10
        }
        set { defaults.set(newValue, forKey: PreferenceKey.morningRecapEndHour) }
    }

    /// Daily-only cadences were removed; stored values that include a daily
    /// component are read back as their closest surviving cadence.
    var historyReportCadence: HistoryReportCadence {
        get {
            let stored = defaults.string(forKey: PreferenceKey.historyReportCadence)
                .flatMap(HistoryReportCadence.init(rawValue:)) ?? .weekly
            return switch stored {
            case .daily: .off
            case .dailyAndWeekly: .weekly
            default: stored
            }
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.historyReportCadence) }
    }

    var historyReportHour: Int {
        get {
            guard defaults.object(forKey: PreferenceKey.historyReportHour) != nil else { return 8 }
            let stored = defaults.integer(forKey: PreferenceKey.historyReportHour)
            return (0...23).contains(stored) ? stored : 8
        }
        set { defaults.set(newValue, forKey: PreferenceKey.historyReportHour) }
    }

    var lastMorningRecapDay: Date? {
        get { defaults.object(forKey: PreferenceKey.lastMorningRecapDay) as? Date }
        set { defaults.set(newValue, forKey: PreferenceKey.lastMorningRecapDay) }
    }

    var lastWeeklyHistoryReport: Date? {
        get { defaults.object(forKey: PreferenceKey.lastWeeklyHistoryReport) as? Date }
        set { defaults.set(newValue, forKey: PreferenceKey.lastWeeklyHistoryReport) }
    }

    static func defaultSmartSleepTargetTime(now: Date = .now) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let approximate = calendar.date(byAdding: .hour, value: 4, to: now) ?? now
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: approximate)
        return calendar.date(from: components) ?? approximate
    }

    var menuBarDisplayMode: MenuBarDisplayMode {
        get {
            defaults.string(forKey: PreferenceKey.menuBarDisplayMode)
                .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .sessionCounts
        }
        set { defaults.set(newValue.rawValue, forKey: PreferenceKey.menuBarDisplayMode) }
    }

    var menuBarUsageWindow: MenuBarUsageWindowSelection? {
        get { decode(MenuBarUsageWindowSelection.self, forKey: PreferenceKey.menuBarUsageWindow) }
        set {
            if let newValue {
                encode(newValue, forKey: PreferenceKey.menuBarUsageWindow)
            } else {
                defaults.removeObject(forKey: PreferenceKey.menuBarUsageWindow)
            }
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode(_ value: some Encodable, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

private enum PreferenceKey {
    static let notificationPolicy = "notificationPolicy"
    static let alertPreferences = "alertPreferences"
    static let sessionOpenPreferences = "sessionOpenPreferences"
    static let sessionFocusPreferences = "sessionFocusPreferences"
    static let hiddenProviders = "hiddenProviders"
    static let dataSourceModes = "dataSourceModes"
    static let smartSleepMode = "smartSleepMode"
    static let smartSleepScheduleMode = "smartSleepScheduleMode"
    static let smartSleepDurationMinutes = "smartSleepDurationMinutes"
    static let smartSleepTargetTime = "smartSleepTargetTime"
    static let sessionDisplayWindow = "sessionDisplayWindow"
    static let visibleSessionStatuses = "visibleSessionStatuses"
    static let maximumVisibleSessions = "maximumVisibleSessions"
    static let showsSessionCacheIcon = "showsSessionCacheIcon"
    static let showsSessionCacheCountdown = "showsSessionCacheCountdown"
    static let showsSessionCacheHits = "showsSessionCacheHits"
    static let cacheReuseDisplayMode = "cacheReuseDisplayMode"
    static let showsCompactSessionRows = "showsCompactSessionRows"
    static let claudeAccountUsageEnabled = "claudeAccountUsageEnabled"
    static let smartSleepExpiresAt = "smartSleepExpiresAt"
    static let remoteHosts = "remoteHosts"
    static let openCodeServers = "openCodeServers"
    static let historyEnabled = "historyEnabled"
    static let historyRetentionDays = "historyRetentionDays"
    static let historyRangeDays = "historyRangeDays"
    static let cacheHitThreshold = "cacheHitThreshold"
    static let morningRecapEnabled = "morningRecapEnabled"
    static let morningRecapStartHour = "morningRecapStartHour"
    static let morningRecapEndHour = "morningRecapEndHour"
    static let historyReportCadence = "historyReportCadence"
    static let historyReportHour = "historyReportHour"
    static let lastMorningRecapDay = "lastMorningRecapDay"
    static let lastWeeklyHistoryReport = "lastWeeklyHistoryReport"
    static let menuBarDisplayMode = "menuBarDisplayMode"
    static let menuBarUsageWindow = "menuBarUsageWindow"
}
