import AgentHearthCore
import Foundation

/// Owns AgentHearth's report delivery: the morning cache recap and the
/// weekly history report. `AppModel` delegates here on every refresh with a
/// value snapshot of the relevant preferences, so scheduling decisions stay
/// testable and out of the model.
@MainActor
final class ReportScheduler {
    /// The preference values a delivery decision depends on, captured by the
    /// caller at refresh time.
    struct Context {
        let historyEnabled: Bool
        let notificationsEnabled: Bool
        let cacheHitThreshold: Int
        let historyReportCadence: HistoryReportCadence
        let historyReportHour: Int
        let morningRecapEnabled: Bool
        let morningRecapStartHour: Int
        let morningRecapEndHour: Int
        let pollingIntervalSeconds: Double
    }

    private let historyStore: HistoryStore
    private let notificationCenter: MacNotificationCenter
    private let preferences: PreferencesStore

    init(
        historyStore: HistoryStore,
        notificationCenter: MacNotificationCenter,
        preferences: PreferencesStore
    ) {
        self.historyStore = historyStore
        self.notificationCenter = notificationCenter
        self.preferences = preferences
    }

    func deliverScheduledHistoryReportIfNeeded(context: Context, now: Date = .now) async {
        guard context.historyEnabled,
              context.historyReportCadence.includesWeekly,
              context.notificationsEnabled
        else { return }
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: now)
        guard let reportTime = calendar.date(byAdding: .hour, value: context.historyReportHour, to: startOfDay),
              now >= reportTime
        else { return }

        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let last = preferences.lastWeeklyHistoryReport
        if let week, last.map({ $0 < week.start }) ?? true {
            let summary = await historyStore.dashboard(
                days: 7,
                cacheHitThreshold: Double(context.cacheHitThreshold) / 100,
                now: now
            )
            if summary.turnCount > 0 {
                await deliverHistoryReport(
                    summary,
                    title: "Weekly cache report",
                    cacheHitThreshold: context.cacheHitThreshold
                )
            }
            preferences.lastWeeklyHistoryReport = now
        }
    }

    func deliverMorningRecapIfNeeded(
        in snapshots: [ProviderSnapshot],
        context: Context,
        now: Date = .now
    ) async {
        guard context.historyEnabled,
              context.morningRecapEnabled,
              context.notificationsEnabled
        else { return }

        let calendar = Calendar.autoupdatingCurrent
        guard let today = calendar.dateInterval(of: .day, for: now),
              let windowStart = calendar.date(byAdding: .hour, value: context.morningRecapStartHour, to: today.start),
              let windowEnd = calendar.date(byAdding: .hour, value: context.morningRecapEndHour, to: today.start),
              now >= windowStart,
              now < windowEnd,
              hasFreshMorningActivity(in: snapshots, now: now, context: context),
              let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: today.start)
        else { return }

        let lastRecapDay = preferences.lastMorningRecapDay
        guard lastRecapDay.map({ !calendar.isDate($0, inSameDayAs: yesterdayStart) }) ?? true else {
            return
        }

        let summary = await historyStore.dashboard(
            startsAt: yesterdayStart,
            endsAt: today.start,
            cacheHitThreshold: Double(context.cacheHitThreshold) / 100
        )
        // Mark the day handled even when there is nothing to recap: yesterday's
        // history will not change, so re-running the aggregation on every
        // refresh for the rest of the window would be pure waste.
        preferences.lastMorningRecapDay = yesterdayStart
        guard summary.turnCount > 0 else { return }
        await deliverMorningRecap(summary)
    }

    private func hasFreshMorningActivity(
        in snapshots: [ProviderSnapshot],
        now: Date,
        context: Context
    ) -> Bool {
        let freshness = max(120, context.pollingIntervalSeconds * 2)
        return snapshots
            .flatMap(\.sessions)
            .contains { session in
                session.status == .working
                    || now.timeIntervalSince(session.lastActivityAt) <= freshness
            }
    }

    private func deliverMorningRecap(_ summary: HistoryDashboardSnapshot) async {
        let reuse = summary.cacheReuseRate.map { "\($0.formatted(.percent.precision(.fractionLength(0)))) reuse" }
            ?? "No cache measurement"
        let global = "\(reuse) · \(compactTokens(summary.uncachedInputTokens)) uncached · \(summary.turnCount) turns"
        let projects = summary.projects.prefix(2).map { project in
            "\(project.projectName): \(compactTokens(project.uncachedInputTokens)) uncached (\(project.cacheReuseRate?.formatted(.percent.precision(.fractionLength(0))) ?? "—"))"
        }
        let details = ([global] + projects).joined(separator: "\n")
        _ = await notificationCenter.deliver(
            AgentAlert(
                id: UUID().uuidString,
                sourceID: .agentHearth,
                type: "history.morningRecap",
                severity: .information,
                title: "Yesterday's cache recap",
                summary: details,
                fingerprint: "history-morning-recap:\(summary.startsAt.timeIntervalSince1970)"
            ),
            playSound: false
        )
    }

    private func deliverHistoryReport(
        _ summary: HistoryDashboardSnapshot,
        title: String,
        cacheHitThreshold: Int
    ) async {
        let rate = summary.cacheReuseRate.map { Int(($0 * 100).rounded()) }
        let rateText = rate.map { "\($0)% cache reuse" } ?? "No measured turns"
        _ = await notificationCenter.deliver(
            AgentAlert(
                id: UUID().uuidString,
                sourceID: .agentHearth,
                type: "history.report",
                severity: .information,
                title: title,
                summary: "\(rateText) · \(summary.hitCount)/\(summary.turnCount) turns ≥ \(cacheHitThreshold)%",
                fingerprint: "history-report:\(title):\(Date.now.timeIntervalSince1970)"
            ),
            playSound: false
        )
    }

    private func compactTokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
