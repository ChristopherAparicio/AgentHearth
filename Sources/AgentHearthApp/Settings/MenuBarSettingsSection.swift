import AgentHearthCore
import SwiftUI

/// The Menu Bar section: a live preview of the status item plus the ordered,
/// editable list of items shown next to the flame.
struct MenuBarSettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Menu Bar") {
            preview

            Toggle("Show flame icon", isOn: Binding(
                get: { model.menuBarLayout.effectiveShowsFlame },
                set: { model.menuBarLayout.showsFlame = $0 }
            ))
            .disabled(model.menuBarLayout.items.isEmpty)

            ForEach(model.menuBarLayout.items) { item in
                MenuBarItemEditor(
                    model: model,
                    item: binding(for: item.id),
                    isFirst: item.id == model.menuBarLayout.items.first?.id,
                    isLast: item.id == model.menuBarLayout.items.last?.id
                )
            }

            Menu {
                ForEach(MenuBarMetricKind.allCases) { kind in
                    Button(kind.label) {
                        model.menuBarLayout.items.append(MenuBarItem(metric: kind.defaultMetric))
                    }
                }
            } label: {
                Label("Add item", systemImage: "plus")
            }
            .fixedSize()

            Text("Items appear left to right in this order. Colored items are drawn in their own color; automatic ones follow the menu bar. An item whose provider reports no data is skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Mirrors the status item on a menu-bar-like strip, in both appearances,
    /// so a color choice can be judged before it lands in the menu bar.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                previewStrip(dark: false)
                previewStrip(dark: true)
            }
        }
    }

    private func previewStrip(dark: Bool) -> some View {
        MenuBarLabelView(
            items: model.menuBarRenderedItems,
            showsFlame: model.menuBarLayout.effectiveShowsFlame,
            baseColor: dark ? .white : .black
        )
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            dark ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1))
                : Color(nsColor: NSColor(calibratedWhite: 0.93, alpha: 1)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func binding(for itemID: UUID) -> Binding<MenuBarItem> {
        Binding(
            get: {
                model.menuBarLayout.items.first { $0.id == itemID }
                    ?? MenuBarItem(metric: .sessionCount(.all))
            },
            set: { updated in
                guard let index = model.menuBarLayout.items.firstIndex(where: { $0.id == itemID }) else { return }
                model.menuBarLayout.items[index] = updated
            }
        )
    }
}

/// One editable item row: metric, scope, refinements, prefix, color, and the
/// reorder/remove controls.
private struct MenuBarItemEditor: View {
    let model: AppModel
    @Binding var item: MenuBarItem
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Metric", selection: metricKind) {
                    ForEach(MenuBarMetricKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("Scope", selection: $item.scope) {
                    ForEach(MenuBarScope.allChoices, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                if case let .sessionCount(filter) = item.metric {
                    Picker("Sessions", selection: Binding(
                        get: { filter },
                        set: { item.metric = .sessionCount($0) }
                    )) {
                        ForEach(MenuBarSessionFilter.allCases, id: \.self) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                if case let .usageWindow(windowID) = item.metric {
                    Picker("Window", selection: Binding(
                        get: { windowID },
                        set: { item.metric = .usageWindow(windowID: $0) }
                    )) {
                        Text("Highest usage").tag(String?.none)
                        ForEach(model.availableUsageWindows(in: item.scope, current: windowID)) { choice in
                            Text(choice.label).tag(Optional(choice.windowID))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                Spacer(minLength: 0)

                Button { model.moveMenuBarItem(item.id, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(isFirst)
                Button { model.moveMenuBarItem(item.id, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(isLast)
                Button(role: .destructive) { model.removeMenuBarItem(item.id) } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)

            HStack(spacing: 8) {
                Picker("Color", selection: $item.tint) {
                    ForEach(MenuBarTint.allCases, id: \.self) { tint in
                        Label {
                            Text(tint.label)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(tint.color ?? .primary)
                        }
                        .tag(tint)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("Prefix", selection: prefixKind) {
                    ForEach(MenuBarPrefixKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                if case let .text(text) = item.prefix {
                    TextField("Prefix", text: Binding(
                        get: { text },
                        set: { item.prefix = .text(String($0.prefix(6))) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                }

                Toggle("Hide when 0", isOn: $item.hidesWhenZero)
                    .toggleStyle(.checkbox)

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private var metricKind: Binding<MenuBarMetricKind> {
        Binding(
            get: { MenuBarMetricKind(item.metric) },
            set: { kind in
                guard kind != MenuBarMetricKind(item.metric) else { return }
                item.metric = kind.defaultMetric
            }
        )
    }

    private var prefixKind: Binding<MenuBarPrefixKind> {
        Binding(
            get: { MenuBarPrefixKind(item.prefix) },
            set: { kind in
                switch kind {
                case .none: item.prefix = .none
                case .providerSymbol: item.prefix = .providerSymbol
                case .text:
                    if case .text = item.prefix { return }
                    item.prefix = .text("")
                }
            }
        )
    }
}
