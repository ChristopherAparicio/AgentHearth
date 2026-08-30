import AgentHearthCore
import SwiftUI

/// The History & Reports section: local storage, retention, dashboard
/// defaults, and the recap/report schedules.
struct HistoryReportsSettingsSection: View {
    @Bindable var model: AppModel
    @Binding var isConfirmingHistoryClear: Bool

    var body: some View {
        Section("History & Reports") {
            Toggle("Store cache history on this Mac", isOn: $model.historyEnabled)

            settingsControlRow("Retention") {
                Picker("Retention", selection: $model.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.settingsLabel).tag(retention)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .disabled(!model.historyEnabled)

            settingsControlRow("Default dashboard period") {
                Picker("Dashboard period", selection: $model.historyRangeDays) {
                    Text("24 hours").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .disabled(!model.historyEnabled)

            settingsControlRow("Cache-hit threshold") {
                Picker("Cache-hit threshold", selection: $model.cacheHitThreshold) {
                    ForEach([50, 60, 70, 80, 90, 95], id: \.self) { threshold in
                        Text("\(threshold)% reused input").tag(threshold)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .disabled(!model.historyEnabled)

            MorningRecapControls(model: model)

            settingsControlRow("Weekly report") {
                Picker("Automatic report", selection: $model.historyReportCadence) {
                    ForEach([HistoryReportCadence.off, .weekly]) { cadence in
                        Text(cadence.settingsLabel).tag(cadence)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .disabled(!model.historyEnabled)

            if model.historyReportCadence.includesWeekly {
                settingsControlRow("Weekly report time") {
                    Picker("Notification time", selection: $model.historyReportHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .disabled(!model.historyEnabled)
            }

            HStack {
                Button("Open Cache Insights") {
                    HistoryWindowPresenter.shared.show(model: model)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.historyEnabled)

                Button("Clear History", role: .destructive) {
                    isConfirmingHistoryClear = true
                }
                .disabled(model.historyDashboard.storageBytes == 0)

                Spacer()

                Text(ByteCountFormatter.string(
                    fromByteCount: model.historyDashboard.storageBytes,
                    countStyle: .file
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("Only token totals, provider, machine, project name, session title, and timestamps are stored. Prompts, responses, source files, and tool payloads are never written to this database. A cache hit is a completed turn whose reused input reaches the configured threshold. Expired rows are purged automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MorningRecapControls: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            Toggle("Morning recap on first activity", isOn: $model.morningRecapEnabled)
                .disabled(!model.historyEnabled)

            if model.morningRecapEnabled {
                HStack {
                    Text("Morning recap window")
                    Spacer()
                    Picker("Start", selection: $model.morningRecapStartHour) {
                        ForEach(0..<23, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    Text("to")
                        .foregroundStyle(.secondary)

                    Picker("End", selection: $model.morningRecapEndHour) {
                        ForEach((model.morningRecapStartHour + 1)...23, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .disabled(!model.historyEnabled)

                Text("Once, when AgentHearth first sees activity in this window. The notification summarizes the previous day and its most cache-expensive projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension HistoryRetention {
    var settingsLabel: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .ninetyDays: "90 days"
        case .oneYear: "1 year"
        }
    }
}

private extension HistoryReportCadence {
    var settingsLabel: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .dailyAndWeekly: "Daily + weekly"
        }
    }
}
