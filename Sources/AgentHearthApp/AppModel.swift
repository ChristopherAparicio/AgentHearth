import AgentHearthCore
import Foundation
import Observation

enum ProviderSelection: Hashable {
    case all
    case provider(AgentProviderID)
}

enum HostSelection: Hashable {
    case all
    case host(String)
}

enum OpenCodeServerSelection: Hashable {
    case all
    case server(String)
}

enum HistoryReportCadence: String, CaseIterable, Codable, Identifiable {
    case off
    case daily
    case weekly
    case dailyAndWeekly

    var id: Self { self }
    var includesDaily: Bool { self == .daily || self == .dailyAndWeekly }
    var includesWeekly: Bool { self == .weekly || self == .dailyAndWeekly }
}

/// The composition root and core UI state of AgentHearth. Owns the snapshot
/// refresh loop, the menu-bar selection and filter state, the history
/// dashboard, and session opening — and wires the single-purpose services
/// (`RemoteHostsService`, `OpenCodeServersService`,
/// `ConnectorInstallationService`, `SmartSleepControl`, `AccountUsagePoller`,
/// `NotificationAdminService`, `AlertRulesService`, `SessionFocusService`)
/// that carry every other responsibility.
@MainActor
@Observable
final class AppModel {
    let monitor: ProviderMonitor
    let historyStore: HistoryStore
    private let connectorServer: AgentHearthLocalServer
    private let alertDetector: SnapshotAlertDetector
    private let notificationCenter: MacNotificationCenter
    let sessionOpener: any SessionOpening
    private let preferences: PreferencesStore
    private let connectorGraph: ConnectorGraphBuilder
    private let reportScheduler: ReportScheduler
    private var monitoringTask: Task<Void, Never>?
    private var hasStarted = false

    let remoteHostsService: RemoteHostsService
    let openCodeServersService: OpenCodeServersService
    let connectorInstallation: ConnectorInstallationService
    let smartSleep: SmartSleepControl
    let accountUsagePoller: AccountUsagePoller
    let notificationAdmin: NotificationAdminService
    let alertRules: AlertRulesService
    let sessionFocus: SessionFocusService

    var snapshots: [ProviderSnapshot] = []
    var selection: ProviderSelection = .all
    var hostSelection: HostSelection = .all
    var openCodeServerSelection: OpenCodeServerSelection = .all
    var hiddenProviders: Set<AgentProviderID> {
        didSet {
            guard hiddenProviders != oldValue else { return }
            preferences.hiddenProviders = hiddenProviders
            normalizeSelection()
        }
    }
    var dataSourceModes: [AgentProviderID: ProviderDataSourceMode] {
        didSet {
            guard dataSourceModes != oldValue else { return }
            preferences.dataSourceModes = dataSourceModes
        }
    }
    var lastRefreshAt: Date?
    var isRefreshing = false
    var notificationPolicy: NotificationPolicy {
        didSet {
            guard notificationPolicy != oldValue else { return }
            preferences.notificationPolicy = notificationPolicy
        }
    }
    var connectorServerError: String?
    var sessionOpeningError: String?
    var sessionOpenPreferences: SessionOpenPreferences {
        didSet {
            guard sessionOpenPreferences != oldValue else { return }
            preferences.sessionOpenPreferences = sessionOpenPreferences
        }
    }
    var sessionDisplayWindow: SessionDisplayWindow {
        didSet {
            guard sessionDisplayWindow != oldValue else { return }
            preferences.sessionDisplayWindow = sessionDisplayWindow
            normalizeSelection()
        }
    }
    var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            guard menuBarDisplayMode != oldValue else { return }
            preferences.menuBarDisplayMode = menuBarDisplayMode
        }
    }

    var menuBarUsageWindow: MenuBarUsageWindowSelection? {
        didSet {
            guard menuBarUsageWindow != oldValue else { return }
            preferences.menuBarUsageWindow = menuBarUsageWindow
        }
    }

    var visibleSessionStatuses: Set<SessionStatus> {
        didSet {
            guard visibleSessionStatuses != oldValue else { return }
            preferences.visibleSessionStatuses = visibleSessionStatuses
            normalizeSelection()
        }
    }
    var maximumVisibleSessions: Int {
        didSet {
            guard maximumVisibleSessions != oldValue else { return }
            preferences.maximumVisibleSessions = maximumVisibleSessions
            normalizeSelection()
        }
    }
    var showsSessionCacheIcon: Bool {
        didSet {
            guard showsSessionCacheIcon != oldValue else { return }
            preferences.showsSessionCacheIcon = showsSessionCacheIcon
        }
    }
    var showsSessionCacheCountdown: Bool {
        didSet {
            guard showsSessionCacheCountdown != oldValue else { return }
            preferences.showsSessionCacheCountdown = showsSessionCacheCountdown
        }
    }
    var showsSessionCacheHits: Bool {
        didSet {
            guard showsSessionCacheHits != oldValue else { return }
            preferences.showsSessionCacheHits = showsSessionCacheHits
        }
    }
    var cacheReuseDisplayMode: CacheReuseDisplayMode {
        didSet {
            guard cacheReuseDisplayMode != oldValue else { return }
            preferences.cacheReuseDisplayMode = cacheReuseDisplayMode
        }
    }
    var showsCompactSessionRows: Bool {
        didSet {
            guard showsCompactSessionRows != oldValue else { return }
            preferences.showsCompactSessionRows = showsCompactSessionRows
        }
    }
    var historyEnabled: Bool {
        didSet {
            guard historyEnabled != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var historyRetention: HistoryRetention {
        didSet {
            guard historyRetention != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var historyRangeDays: Int {
        didSet {
            guard historyRangeDays != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var historyProviderFilter: AgentProviderID?
    var cacheHitThreshold: Int {
        didSet {
            guard cacheHitThreshold != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var morningRecapEnabled: Bool {
        didSet {
            guard morningRecapEnabled != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var morningRecapStartHour: Int {
        didSet {
            guard morningRecapStartHour != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var morningRecapEndHour: Int {
        didSet {
            guard morningRecapEndHour != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var historyReportCadence: HistoryReportCadence {
        didSet {
            guard historyReportCadence != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var historyReportHour: Int {
        didSet {
            guard historyReportHour != oldValue else { return }
            persistHistoryPreferences()
        }
    }
    var historyDashboard = HistoryDashboardSnapshot.empty

    init(
        monitor: ProviderMonitor,
        automaticOpenCodeConnector: OpenCodeConnector,
        historyStore: HistoryStore,
        smartSleep smartSleepCoordinator: SmartSleepCoordinator,
        connectorServer: AgentHearthLocalServer,
        openCodeInstaller: OpenCodeConnectorInstaller,
        codexInstaller: CodexConnectorInstaller,
        claudeCodeInstaller: ClaudeCodeConnectorInstaller,
        remoteAgentInstaller: RemoteAgentInstaller,
        alertDetector: SnapshotAlertDetector,
        notificationCenter: MacNotificationCenter,
        sessionOpener: any SessionOpening,
        accountUsageFetcher: any AccountUsageFetching,
        defaults: UserDefaults = .standard,
        bundledOpenCodeConnectorURL: URL?,
        bundledCodexHookURL: URL?,
        bundledClaudeCodeHookURL: URL?,
        bundledRemoteAgentURL: URL?
    ) {
        self.monitor = monitor
        self.historyStore = historyStore
        self.connectorServer = connectorServer
        self.alertDetector = alertDetector
        self.notificationCenter = notificationCenter
        self.sessionOpener = sessionOpener
        let connectorGraph = ConnectorGraphBuilder(
            automaticOpenCodeConnector: automaticOpenCodeConnector
        )
        self.connectorGraph = connectorGraph
        let preferences = PreferencesStore(defaults: defaults)
        self.preferences = preferences
        let reportScheduler = ReportScheduler(
            historyStore: historyStore,
            notificationCenter: notificationCenter,
            preferences: preferences
        )
        self.reportScheduler = reportScheduler
        self.smartSleep = SmartSleepControl(
            coordinator: smartSleepCoordinator,
            preferences: preferences
        )
        self.remoteHostsService = RemoteHostsService(
            installer: remoteAgentInstaller,
            connectorGraph: connectorGraph,
            preferences: preferences,
            bundledRemoteAgentURL: bundledRemoteAgentURL,
            bundledOpenCodePluginURL: bundledOpenCodeConnectorURL
        )
        self.openCodeServersService = OpenCodeServersService(
            connectorGraph: connectorGraph,
            preferences: preferences
        )
        self.connectorInstallation = ConnectorInstallationService(
            openCodeInstaller: openCodeInstaller,
            codexInstaller: codexInstaller,
            claudeCodeInstaller: claudeCodeInstaller,
            bundledOpenCodeConnectorURL: bundledOpenCodeConnectorURL,
            bundledCodexHookURL: bundledCodexHookURL,
            bundledClaudeCodeHookURL: bundledClaudeCodeHookURL
        )
        self.accountUsagePoller = AccountUsagePoller(
            fetcher: accountUsageFetcher,
            preferences: preferences
        )
        self.notificationAdmin = NotificationAdminService(notificationCenter: notificationCenter)
        self.alertRules = AlertRulesService(preferences: preferences)
        self.sessionFocus = SessionFocusService(preferences: preferences)
        self.notificationPolicy = preferences.notificationPolicy
        self.sessionOpenPreferences = preferences.sessionOpenPreferences
        self.hiddenProviders = preferences.hiddenProviders
        self.dataSourceModes = preferences.dataSourceModes
        self.sessionDisplayWindow = preferences.sessionDisplayWindow
        self.visibleSessionStatuses = preferences.visibleSessionStatuses
        self.menuBarDisplayMode = preferences.menuBarDisplayMode
        self.menuBarUsageWindow = preferences.menuBarUsageWindow
        self.maximumVisibleSessions = preferences.maximumVisibleSessions
        self.showsSessionCacheIcon = preferences.showsSessionCacheIcon
        self.showsSessionCacheCountdown = preferences.showsSessionCacheCountdown
        self.showsSessionCacheHits = preferences.showsSessionCacheHits
        self.cacheReuseDisplayMode = preferences.cacheReuseDisplayMode
        self.showsCompactSessionRows = preferences.showsCompactSessionRows
        self.historyEnabled = preferences.historyEnabled
        self.historyRetention = preferences.historyRetention
        self.historyRangeDays = preferences.historyRangeDays
        self.historyProviderFilter = nil
        self.cacheHitThreshold = preferences.cacheHitThreshold
        self.morningRecapEnabled = preferences.morningRecapEnabled
        self.morningRecapStartHour = preferences.morningRecapStartHour
        self.morningRecapEndHour = preferences.morningRecapEndHour
        self.historyReportCadence = preferences.historyReportCadence
        self.historyReportHour = preferences.historyReportHour
        wireServices()
        smartSleep.scheduleExpiration()
    }

    /// Connects the services' composition hooks back to the model. Every
    /// closure captures `self` weakly, so no service retains the model.
    private func wireServices() {
        remoteHostsService.onTopologyChanged = { [weak self] in
            self?.rebuildAdditionalConnectors()
        }
        remoteHostsService.onHostRemoved = { [weak self] hostID in
            self?.openCodeServersService.removeServers(forHost: hostID)
        }
        remoteHostsService.dataSourceModes = { [weak self] in
            self?.dataSourceModes ?? [:]
        }
        openCodeServersService.onTopologyChanged = { [weak self] in
            self?.rebuildAdditionalConnectors()
        }
        openCodeServersService.onServerRemoved = { [weak self] serverID in
            guard let self, self.openCodeServerSelection == .server(serverID) else { return }
            self.openCodeServerSelection = .all
        }
        openCodeServersService.remoteHosts = { [weak self] in
            self?.remoteHostsService.remoteHosts ?? []
        }
        smartSleep.sessions = { [weak self] in
            self?.sessions ?? []
        }
        alertRules.allSessions = { [weak self] in
            self?.snapshots.flatMap(\.sessions) ?? []
        }
        accountUsagePoller.ingest = { [monitor] usage in
            await monitor.ingestAccountUsage(usage)
        }
        notificationAdmin.policy = { [weak self] in
            self?.notificationPolicy ?? NotificationPolicy()
        }
        notificationAdmin.smartSleepMode = { [weak self] in
            self?.smartSleep.mode ?? .off
        }
        notificationAdmin.preserveSettingsWindow = {
            SettingsWindowPresenter.shared.preserveCurrentSettingsWindowForSystemSettings()
        }
    }

    static func live() -> AppModel {
        let openCodeConnector = OpenCodeConnector()
        let codexConnector = CodexConnector()
        let claudeCodeConnector = ClaudeCodeConnector()
        let ingressToken = try? AgentHearthIngressToken.loadOrCreate()
        let server = AgentHearthLocalServer(
            token: ingressToken,
            ingestOpenCode: { payload in
                try await openCodeConnector.ingest(payload)
            },
            ingestCodex: { event in
                try await codexConnector.ingest(event)
            },
            ingestClaudeCode: { event in
                try await claudeCodeConnector.ingest(event)
            },
            ingestClaudeCodeStatus: { event in
                try await claudeCodeConnector.ingest(event)
            }
        )
        let bundledConnector = Bundle.main.url(
            forResource: "agenthearth",
            withExtension: "ts",
            subdirectory: "OpenCode"
        ) ?? Bundle.main.url(forResource: "agenthearth", withExtension: "ts")
        let bundledClaudeHook = Bundle.main.url(
            forResource: "agenthearth_hook",
            withExtension: "py",
            subdirectory: "ClaudeCode"
        ) ?? Bundle.main.url(forResource: "agenthearth_hook", withExtension: "py")
        let bundledCodexHook = Bundle.main.url(
            forResource: "agenthearth_hook",
            withExtension: "py",
            subdirectory: "Codex"
        )
        let bundledRemoteAgent = Bundle.main.url(
            forResource: "agenthearth_remote",
            withExtension: "py",
            subdirectory: "Remote"
        )
        let notifications = MacNotificationCenter()
        let model = AppModel(
            monitor: ProviderMonitor(connectors: [codexConnector, claudeCodeConnector]),
            automaticOpenCodeConnector: openCodeConnector,
            historyStore: HistoryStore(),
            smartSleep: SmartSleepCoordinator(assertion: ProcessInfoSleepAssertion()),
            connectorServer: server,
            openCodeInstaller: OpenCodeConnectorInstaller(),
            codexInstaller: CodexConnectorInstaller(),
            claudeCodeInstaller: ClaudeCodeConnectorInstaller(),
            remoteAgentInstaller: RemoteAgentInstaller(),
            alertDetector: SnapshotAlertDetector(),
            notificationCenter: notifications,
            sessionOpener: TerminalSessionOpener(),
            accountUsageFetcher: ClaudeAccountUsageFetcher(),
            bundledOpenCodeConnectorURL: bundledConnector,
            bundledCodexHookURL: bundledCodexHook,
            bundledClaudeCodeHookURL: bundledClaudeHook,
            bundledRemoteAgentURL: bundledRemoteAgent
        )
        notifications.onOpenTarget = { [weak model] target in
            model?.openSession(target)
        }
        notifications.onIgnoreCurrentCache = { [weak model] target in
            model?.ignoreCacheWarning(for: target)
        }
        notifications.onPromoteSession = { [weak model] target in
            model?.sessionFocus.pin(target: target)
        }
        notifications.onWillPresent = { [weak model] identifier in
            model?.notificationAdmin.markNotificationPresented(identifier)
        }
        model.start()
        return model
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // A menu-bar app can be constructed before it owns an active window.
        // Wait for an explicit settings action before asking macOS for the
        // permission prompt, otherwise the request may not be registered.
        notificationAdmin.refreshAuthorization()

        do {
            try connectorServer.start()
            connectorServerError = nil
        } catch {
            connectorServerError = error.localizedDescription
        }

        let monitor = monitor
        let initialModes = dataSourceModes
        let additionalConnectors = connectorGraph.additionalConnectors(
            remoteHosts: remoteHostsService.remoteHosts,
            openCodeServers: openCodeServersService.openCodeServers
        )
        monitoringTask = Task { [weak self] in
            await monitor.setAdditionalConnectors(additionalConnectors)
            await monitor.setSourceModes(initialModes)
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.nextPollingIntervalSeconds))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await accountUsagePoller.refreshIfNeeded()
        let collectedSnapshots = await monitor.collect()
        let alerts = await alertDetector.detect(
            in: collectedSnapshots,
            preferences: alertRules.preferences,
            focus: sessionFocus.preferences
        )
        if historyEnabled {
            // Remote sessions already reach history through `collectedSnapshots`
            // below, so the separate SSH `history` round-trip was dead work (its
            // events were discarded) — and its large output could deadlock the
            // SSH runner. It is intentionally no longer issued.
            await historyStore.ingest(collectedSnapshots, retentionDays: historyRetention.rawValue)
            historyDashboard = await historyStore.dashboard(
                days: historyRangeDays,
                providerID: historyProviderFilter,
                cacheHitThreshold: Double(cacheHitThreshold) / 100
            )
        }
        snapshots = collectedSnapshots
        // Reconcile against every observed session (hidden providers included)
        // so completed sessions unpin and stale pins age out.
        sessionFocus.reconcile(sessions: snapshots.flatMap(\.sessions))
        alertRules.preferences.pruneCacheAlertStates(using: snapshots.flatMap(\.sessions))
        lastRefreshAt = .now
        normalizeSelection()
        smartSleep.reconcileAfterRefresh(sessions: sessions)
        isRefreshing = false

        for alert in alerts {
            let shouldPlaySound = notificationPolicy.shouldPlaySound(
                for: alert.severity,
                smartSleepMode: smartSleep.mode
            )
            _ = await notificationCenter.deliver(
                alert,
                playSound: shouldPlaySound && alert.soundName == nil
            )
            if shouldPlaySound, let soundName = alert.soundName {
                notificationCenter.playSound(named: soundName)
            }
        }
        await reportScheduler.deliverMorningRecapIfNeeded(in: collectedSnapshots, context: reportContext)
        await reportScheduler.deliverScheduledHistoryReportIfNeeded(context: reportContext)
    }

    var nextPollingIntervalSeconds: Double {
        AdaptivePollingPolicy().interval(for: snapshots)
    }

    private var reportContext: ReportScheduler.Context {
        ReportScheduler.Context(
            historyEnabled: historyEnabled,
            notificationsEnabled: alertRules.preferences.notificationsEnabled,
            cacheHitThreshold: cacheHitThreshold,
            historyReportCadence: historyReportCadence,
            historyReportHour: historyReportHour,
            morningRecapEnabled: morningRecapEnabled,
            morningRecapStartHour: morningRecapStartHour,
            morningRecapEndHour: morningRecapEndHour,
            pollingIntervalSeconds: nextPollingIntervalSeconds
        )
    }

    private func persistHistoryPreferences() {
        let clampedEndHour = min(23, max(morningRecapEndHour, morningRecapStartHour + 1))
        if clampedEndHour != morningRecapEndHour {
            // Assigning re-enters this method through the property's didSet
            // with consistent values, so the persist below runs exactly once.
            morningRecapEndHour = clampedEndHour
            return
        }
        preferences.historyEnabled = historyEnabled
        preferences.historyRetention = historyRetention
        preferences.historyRangeDays = historyRangeDays
        preferences.cacheHitThreshold = cacheHitThreshold
        preferences.morningRecapEnabled = morningRecapEnabled
        preferences.morningRecapStartHour = morningRecapStartHour
        preferences.morningRecapEndHour = morningRecapEndHour
        preferences.historyReportCadence = historyReportCadence
        preferences.historyReportHour = historyReportHour
        Task {
            await historyStore.applyRetention(days: historyRetention.rawValue)
            await refreshHistoryDashboard()
        }
    }

    private func rebuildAdditionalConnectors() {
        let connectors = connectorGraph.additionalConnectors(
            remoteHosts: remoteHostsService.remoteHosts,
            openCodeServers: openCodeServersService.openCodeServers
        )
        let modes = dataSourceModes
        Task {
            await monitor.setAdditionalConnectors(connectors)
            await monitor.setSourceModes(modes)
            await refresh()
        }
    }
}
