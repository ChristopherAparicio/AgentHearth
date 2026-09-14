import AgentHearthCore
import Charts
import SwiftUI

/// Where a usage window went over the last minutes or hours, and which
/// sessions were spending while it went.
///
/// Deliberately separate from the Cache Insights dashboard. That view asks
/// whether the prompt cache is being wasted over days; this one asks what just
/// consumed the 5h window. They also rest on different evidence — account-level
/// readings here, sampled per-turn counters there — and showing two token
/// figures of different provenance side by side would invite comparing numbers
/// that are not meant to agree.
struct ConsumptionView: View {
    @Bindable var model: AppModel

    private var snapshot: ConsumptionSnapshot { model.consumption }
    private var visibleProviders: [AgentProviderID] {
        AgentProviderID.allCases.filter { model.isProviderVisible($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.historyEnabled {
                    disabledState
                } else {
                    if snapshot.timelines.isEmpty {
                        awaitingReadings
                    } else {
                        ForEach(snapshot.timelines) { timeline in
                            timelineCard(timeline)
                        }
                    }
                    if !model.inFlightSessions.isEmpty { inFlight }
                    if !snapshot.sessions.isEmpty { ranked }
                    if snapshot.sessions.isEmpty && model.inFlightSessions.isEmpty { noSessions }
                }
                footer
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.red.gradient)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent consumption").font(.title2.weight(.semibold))
                    Text("What moved your usage windows, and what was running while it moved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 14) {
                Picker("Provider", selection: $model.consumptionProviderFilter) {
                    Text("All").tag(AgentProviderID?.none)
                    ForEach(visibleProviders) { providerID in
                        Text(providerID.displayName).tag(Optional(providerID))
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 400, alignment: .leading)

                Spacer(minLength: 20)

                Picker("Range", selection: rangeSelection) {
                    if let selection = model.consumptionSelection {
                        // Labelled with the range it stands for, so the picker
                        // says what is on screen instead of merely that it is
                        // not one of the presets. Leaving it is picking another.
                        Text(
                            "\(selection.lowerBound.formatted(date: .omitted, time: .shortened))–"
                                + "\(selection.upperBound.formatted(date: .omitted, time: .shortened))"
                        ).tag(Self.brushedRangeTag)
                    }
                    Text("1 h").tag(60)
                    Text("1 j").tag(1_440)
                    Text("7 j").tag(10_080)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: model.consumptionSelection == nil ? 200 : 320)
                .help("Drag across a chart to scope everything to that stretch")
            }
            .onChange(of: model.consumptionProviderFilter) {
                Task { await model.refreshConsumption() }
            }

        }
    }

    // MARK: - Usage windows

    private func timelineCard(_ timeline: UsageTimeline) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    HistoryMetricCard(
                        title: "Now",
                        value: percent(timeline.latestFraction),
                        detail: "of the \(timeline.label) window",
                        symbol: "gauge.with.needle",
                        color: UsagePresentation.tint(
                            for: timeline.latestFraction ?? 0,
                            base: timeline.providerID.tint
                        )
                    )
                    HistoryMetricCard(
                        title: "Window spent",
                        value: "\(Int(timeline.consumedPoints.rounded()))%",
                        detail: "of the window \(rangeLabel)",
                        symbol: "arrow.down.right.circle",
                        color: .orange,
                        info: "How much of this window was consumed across the range, as a percent of one full window. Rises between readings are summed, so a window that reset mid-range still reports what was actually spent — and a range covering several resets can exceed 100%."
                    )
                    HistoryMetricCard(
                        title: "Fastest stretch",
                        value: surgeValue(timeline.steepestSurge),
                        detail: surgeDetail(timeline.steepestSurge),
                        symbol: "bolt.fill",
                        color: .red,
                        info: "The steepest pair of readings in the range — where the window actually went, as a percent of one full window. Ranked by rate, so a long quiet gap cannot outrank a genuine burst."
                    )
                }
                chart(timeline)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label("\(timeline.providerID.displayName) · \(timeline.label)", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                if timeline.hostName != AgentHost.local.displayName {
                    Text(timeline.hostName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
                Text("\(timeline.points.count) readings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Stands for a brushed range in the picker. Zero is safe: a real range is
    /// always at least one minute.
    private static let brushedRangeTag = 0

    /// The picker reads the brush when there is one and the preset otherwise,
    /// and picking a preset is what releases the brush — so the presets can
    /// never look dead while a zoom outranks them.
    private var rangeSelection: Binding<Int> {
        Binding(
            get: {
                if model.consumptionSelection != nil { return Self.brushedRangeTag }
                return [60, 1_440, 10_080].contains(model.consumptionRangeMinutes)
                    ? model.consumptionRangeMinutes
                    : 1_440
            },
            set: { picked in
                guard picked != Self.brushedRangeTag else { return }
                model.consumptionSelection = nil
                model.consumptionRangeMinutes = picked
            }
        )
    }

    /// Live extent of the drag, in plot coordinates, so the selection is
    /// visible while it is being made. Cleared on release; the committed range
    /// lives on the model.
    @State private var brush: (CGFloat, CGFloat)?

    private func chart(_ timeline: UsageTimeline) -> some View {
        Chart {
            ForEach(timeline.points) { point in
                LineMark(
                    x: .value("Time", point.measuredAt),
                    y: .value("Used", point.usedFraction * 100)
                )
                .foregroundStyle(timeline.providerID.tint)
            }
            if let surge = timeline.steepestSurge {
                RectangleMark(
                    xStart: .value("Burst start", surge.startedAt),
                    xEnd: .value("Burst end", surge.endedAt)
                )
                .foregroundStyle(.red.opacity(0.12))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        // Commit on release, not while dragging. `chartXSelection(range:)`
        // reports a live hover and clears it on mouse-up, which reads as a
        // zoom that undoes itself — and refetches on every pixel on the way.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { brush = ($0.startLocation.x, $0.location.x) }
                            .onEnded { drag in
                                brush = nil
                                guard let plot = proxy.plotFrame else { return }
                                let origin = geometry[plot].origin.x
                                guard let a: Date = proxy.value(atX: drag.startLocation.x - origin),
                                      let b: Date = proxy.value(atX: drag.location.x - origin),
                                      abs(a.timeIntervalSince(b)) >= 60
                                else { return }
                                model.consumptionSelection = min(a, b) ... max(a, b)
                            }
                    )
                    .overlay(alignment: .leading) {
                        if let brush {
                            Rectangle()
                                .fill(.tint.opacity(0.18))
                                .frame(width: abs(brush.1 - brush.0))
                                .offset(x: min(brush.0, brush.1))
                        }
                    }
            }
        }
        .frame(height: 150)
    }

    // MARK: - Sessions

    private var inFlight: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(model.inFlightSessions.prefix(6).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape.2.fill")
                            .foregroundStyle(session.providerID.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.projectName ?? session.titleWithoutProviderPrefix)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(session.titleWithoutProviderPrefix)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(tokens(model.inFlightCost(session))) this turn")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                            Text(session.model.map(modelLabel) ?? session.providerID.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 9)
                }
            }
        } label: {
            HStack {
                Label("Working now", systemImage: "bolt.horizontal.circle")
                    .font(.headline)
                Spacer()
                HelpButton(text: "A turn is only recorded once it finishes, so these sessions contribute nothing to the ranking below however much they are spending. The figure is their current turn, not a total for the range — which is exactly the shape a runaway loop takes.")
            }
        }
    }

    private var ranked: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.sessions.prefix(10).enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(session.providerID.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(context(session))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(tokens(session.billableTokens))
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                            Text("\(tokens(session.uncachedInputTokens)) in · \(tokens(session.outputTokens)) out")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        } label: {
            HStack {
                Label("Measured turns", systemImage: "list.number")
                    .font(.headline)
                Spacer()
                Text("ranked by billable tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HelpButton(text: "Uncached input plus output — what the provider had to process or generate at full price. Cached reads are excluded: they cost far less, and counting them would rank a large warm session above a smaller one reprocessing its whole context every turn.")
            }
        }
    }

    // MARK: - Empty and disabled states

    private var awaitingReadings: some View {
        emptyBox(
            symbol: "clock.badge.questionmark",
            title: "No usage readings in this range",
            detail: "Usage figures only refresh when a session of that provider reports them. Run an agent, or widen the range."
        )
    }

    private var noSessions: some View {
        emptyBox(
            symbol: "moon.zzz",
            title: "No measured turns in this range",
            detail: "Nothing finished a turn here. A window that moved anyway was spent by a session still working, or from another machine."
        )
    }

    private var disabledState: some View {
        emptyBox(
            symbol: "externaldrive.badge.xmark",
            title: "Local history is off",
            detail: "This view reads the local history database. Switch it on in Settings → History."
        )
    }

    private func emptyBox(symbol: String, title: String, detail: String) -> some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        }
    }

    private var footer: some View {
        Text("Windows are the provider's own account-level readings. The session ranking is AgentHearth's per-turn sampling, so a session's share of a window is a ranking, not an audit: with several agents running, nothing in the counters says which one moved the account figure.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Formatting

    private var rangeLabel: String {
        if let selection = model.consumptionSelection {
            let minutes = Int(selection.upperBound.timeIntervalSince(selection.lowerBound) / 60)
            return "over the \(CompactDuration(TimeInterval(max(1, minutes) * 60)).text) selected"
        }
        switch model.consumptionRangeMinutes {
        case 60: return "in the last hour"
        case 10_080: return "in the last 7 days"
        default: return "in the last 24 hours"
        }
    }

    private func surgeValue(_ surge: UsageSurge?) -> String {
        guard let surge else { return "—" }
        return "\(Int(surge.gainedPoints.rounded()))%"
    }

    private func surgeDetail(_ surge: UsageSurge?) -> String {
        guard let surge else { return "No rise measured" }
        let minutes = max(1, Int((surge.elapsed / 60).rounded()))
        return "of the window in \(minutes) min, at \(surge.startedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func context(_ session: SessionHistorySummary) -> String {
        [session.providerID.displayName, session.sourceName ?? session.hostName,
         "\(session.turnCount) turns"]
            .joined(separator: " · ")
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    /// Drops a trailing dated snapshot suffix so a model name stays on one line.
    private func modelLabel(_ identifier: String) -> String {
        let parts = identifier.split(separator: "-")
        guard let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) else { return identifier }
        return parts.dropLast().joined(separator: "-")
    }
}
