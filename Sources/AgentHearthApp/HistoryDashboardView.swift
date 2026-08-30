import AgentHearthCore
import Charts
import SwiftUI

struct HistoryDashboardView: View {
    @Bindable var model: AppModel

    private var snapshot: HistoryDashboardSnapshot { model.historyDashboard }
    private var visibleProviders: [AgentProviderID] {
        AgentProviderID.allCases.filter { model.isProviderVisible($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.historyEnabled {
                    disabledState
                } else if snapshot.turnCount == 0 {
                    emptyState
                } else {
                    metrics
                    activityChart
                    projects
                    sessions
                }
                footer
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 580)
        .task { await model.refreshHistoryDashboard() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.orange.gradient)
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Cache Insights").font(.title2.weight(.bold))
                    Text("Token reuse measured on completed provider turns")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 14) {
                providerFilter

                Spacer(minLength: 20)

                Picker("Period", selection: $model.historyRangeDays) {
                    Text("24h").tag(1)
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            .onChange(of: model.historyProviderFilter) {
                Task { await model.refreshHistoryDashboard() }
            }
        }
    }

    @ViewBuilder
    private var providerFilter: some View {
        if visibleProviders.count > 3 {
            Picker("Provider", selection: $model.historyProviderFilter) {
                Text("All providers").tag(AgentProviderID?.none)
                ForEach(visibleProviders) { providerID in
                    Text(providerID.displayName).tag(Optional(providerID))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180, alignment: .leading)
        } else {
            Picker("Provider", selection: $model.historyProviderFilter) {
                Text("All").tag(AgentProviderID?.none)
                ForEach(visibleProviders) { providerID in
                    Text(providerID.displayName).tag(Optional(providerID))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 600, alignment: .leading)
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            HistoryMetricCard(
                title: "Cache reuse",
                value: percent(snapshot.cacheReuseRate),
                detail: "\(tokens(snapshot.cachedInputTokens)) cached of \(tokens(snapshot.inputTokens)) input",
                symbol: "arrow.triangle.2.circlepath",
                color: color(for: snapshot.cacheReuseRate)
            )
            HistoryMetricCard(
                title: "Cache hits",
                value: percent(snapshot.hitRate),
                detail: "\(snapshot.hitCount) of \(snapshot.turnCount) turns",
                symbol: "checkmark.circle.fill",
                color: .green,
                info: "A hit is a completed turn whose reused input reaches \(model.cacheHitThreshold)% or more. Change the threshold in Settings."
            )
            HistoryMetricCard(
                title: "Uncached input",
                value: tokens(snapshot.uncachedInputTokens),
                detail: "\(tokens(snapshot.inputTokens)) total input",
                symbol: "arrow.down.circle",
                color: .orange
            )
            HistoryMetricCard(
                title: "Output",
                value: tokens(snapshot.outputTokens),
                detail: "Across \(snapshot.turnCount) completed turns",
                symbol: "arrow.up.circle",
                color: .blue
            )
        }
    }

    private var activityChart: some View {
        GroupBox {
            Chart(snapshot.buckets) { bucket in
                if let reuse = bucket.cacheReuseRate {
                    LineMark(x: .value("Day", bucket.day, unit: .day), y: .value("Reuse", reuse * 100))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.tint)
                    PointMark(x: .value("Day", bucket.day, unit: .day), y: .value("Reuse", reuse * 100))
                        .foregroundStyle(.tint)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 210)
            .padding(.top, 8)
        } label: {
            HStack {
                Label("Token-weighted cache reuse", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text("daily")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sessions: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    sessionRow(session)
                        .padding(.vertical, 11)
                }
            }
        } label: {
            HStack {
                Label("Sessions", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Text("\(snapshot.sessions.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var projects: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.projects.prefix(5).enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.projectName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text("\(project.turnCount) measured turns")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(tokens(project.uncachedInputTokens)) uncached")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                            Text("\(percent(project.cacheReuseRate)) reused · \(tokens(project.inputTokens)) input")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 9)
                }
            }
        } label: {
            HStack {
                Label("Projects to optimize", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                Text("ranked by uncached input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRow(_ session: SessionHistorySummary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(session.providerID.tint.opacity(0.12))
                Image(systemName: session.providerID.symbolName)
                    .foregroundStyle(session.providerID.tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text([session.providerID.displayName, session.hostName, session.sourceName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(percent(session.cacheReuseRate)) cache · \(session.hitCount)/\(session.turnCount) turns")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(color(for: session.cacheReuseRate))
                Text("\(tokens(session.cachedInputTokens)) cached · \(tokens(session.uncachedInputTokens)) uncached · \(tokens(session.outputTokens)) output")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 300, alignment: .trailing)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No measured turns yet",
            systemImage: "chart.bar.xaxis",
            description: Text("Insights records completed provider turns when input and cache-token telemetry are available.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var disabledState: some View {
        ContentUnavailableView(
            "History is disabled",
            systemImage: "clock.badge.xmark",
            description: Text("Enable bounded local history in Settings to build cache reports.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var footer: some View {
        HStack {
            Label(
                ByteCountFormatter.string(fromByteCount: snapshot.storageBytes, countStyle: .file),
                systemImage: "internaldrive"
            )
            Text("·")
            Text("Retention: \(model.historyRetention.rawValue) days")
            Text("·")
            Text("Hit threshold: \(model.cacheHitThreshold)%")
            Spacer()
            Button("Refresh") {
                Task { await model.refreshHistoryDashboard() }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func color(for rate: Double?) -> Color {
        CacheReusePresentation.tint(for: rate)
    }
}

private struct HistoryMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let color: Color
    let info: String?

    init(
        title: String,
        value: String,
        detail: String,
        symbol: String,
        color: Color,
        info: String? = nil
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.color = color
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                Spacer()
                if let info {
                    HelpButton(text: info)
                }
            }
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HelpButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(width: 250, alignment: .leading)
        }
    }
}
