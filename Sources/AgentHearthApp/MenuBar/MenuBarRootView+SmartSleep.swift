import AgentHearthCore
import SwiftUI

extension MenuBarRootView {
    var smartSleepSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(smartSleepColor.opacity(0.14))
                    Image(systemName: model.smartSleep.isHoldingAssertion ? "moon.zzz.fill" : "moon.zzz")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(smartSleepColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Smart Sleep")
                        .font(.subheadline.weight(.semibold))
                    Text(smartSleepSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Smart Sleep", selection: Binding(
                    get: { model.smartSleep.mode },
                    set: { model.smartSleep.setMode($0) }
                )) {
                    Text("Off").tag(SmartSleepMode.off)
                    Text("Keep Awake").tag(SmartSleepMode.keepAwake)
                    Text("Night").tag(SmartSleepMode.night)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 116)
            }

            if model.smartSleep.mode != .off {
                smartSleepScheduleControls
                    .padding(.leading, 45)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.smartSleep.mode)
    }

    private var smartSleepScheduleControls: some View {
        HStack(spacing: 8) {
            Text("Allow sleep")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Picker("Limit", selection: Binding(
                get: { model.smartSleep.scheduleMode },
                set: { model.smartSleep.setScheduleMode($0) }
            )) {
                Text("No limit").tag(SmartSleepScheduleMode.unlimited)
                Text("For").tag(SmartSleepScheduleMode.duration)
                Text("Until").tag(SmartSleepScheduleMode.targetTime)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 92)

            switch model.smartSleep.scheduleMode {
            case .unlimited:
                EmptyView()
            case .duration:
                Picker("Duration", selection: Binding(
                    get: { model.smartSleep.durationMinutes },
                    set: { model.smartSleep.setDurationMinutes($0) }
                )) {
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                    Text("8 hours").tag(480)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 94)
            case .targetTime:
                DatePicker(
                    "Target time",
                    selection: Binding(
                        get: { model.smartSleep.targetTime },
                        set: { model.smartSleep.setTargetTime($0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 92)
            }
        }
    }

    private var smartSleepColor: Color {
        switch model.smartSleep.mode {
        case .off: .secondary
        case .keepAwake: .blue
        case .night: .purple
        }
    }

    private var smartSleepSubtitle: String {
        switch model.smartSleep.mode {
        case .off:
            "Disabled"
        case .keepAwake:
            smartSleepTimedSubtitle(
                active: "Keeping active agents awake",
                ready: "Ready when work starts"
            )
        case .night:
            smartSleepTimedSubtitle(
                active: "Working quietly overnight",
                ready: "Quiet mode ready"
            )
        }
    }

    private func smartSleepTimedSubtitle(active: String, ready: String) -> String {
        let base = model.smartSleep.isHoldingAssertion ? active : ready
        guard let expiresAt = model.smartSleep.expiresAt else { return base }

        switch model.smartSleep.scheduleMode {
        case .unlimited:
            return base
        case .duration:
            let seconds = max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
            let totalMinutes = max(1, (seconds + 59) / 60)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            let remaining: String
            if hours > 0, minutes > 0 {
                remaining = "\(hours)h \(minutes)m left"
            } else if hours > 0 {
                remaining = "\(hours)h left"
            } else {
                remaining = "\(minutes)m left"
            }
            return "\(base) · \(remaining)"
        case .targetTime:
            let time = expiresAt.formatted(date: .omitted, time: .shortened)
            let day = Calendar.autoupdatingCurrent.isDateInTomorrow(expiresAt) ? "tomorrow " : ""
            return "\(base) · sleep at \(day)\(time)"
        }
    }
}
