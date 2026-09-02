import AgentHearthCore
import AppKit
import SwiftUI

/// The composed status-item content: the optional flame followed by the
/// rendered items, separated by middle dots. Used verbatim by the Settings
/// preview and, rasterized when custom colors are involved, by the status
/// item itself.
struct MenuBarLabelView: View {
    let items: [MenuBarRenderedItem]
    let showsFlame: Bool
    /// Text color for `.automatic` items and the flame.
    var baseColor: Color = .primary

    var body: some View {
        HStack(spacing: 4) {
            if showsFlame {
                Image(systemName: "flame.fill")
                    .foregroundStyle(baseColor)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 || showsFlame {
                    Text("·")
                        .foregroundStyle(baseColor.opacity(0.55))
                }
                HStack(spacing: 2) {
                    if let provider = item.providerSymbol {
                        Image(systemName: provider.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    if let prefix = item.prefixText {
                        Text(prefix)
                    }
                    Text(item.text)
                }
                .foregroundStyle(item.tint.color ?? baseColor)
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .monospacedDigit()
        .fixedSize()
    }
}

/// The `MenuBarExtra` label. `MenuBarExtra` draws its label as a template
/// image, which discards colors, so the composition is rasterized into a
/// non-template image whenever an item carries a custom tint or a provider
/// glyph. With automatic tints only, the plain view is used so the text keeps
/// following the menu bar's own appearance exactly.
struct MenuBarStatusLabel: View {
    let items: [MenuBarRenderedItem]
    let showsFlame: Bool

    private var needsRasterization: Bool {
        items.contains { $0.tint != .automatic || $0.providerSymbol != nil }
    }

    var body: some View {
        if needsRasterization, let image = rasterized() {
            Image(nsImage: image)
        } else {
            // `effectiveShowsFlame` guarantees this never renders empty.
            HStack(spacing: 4) {
                if showsFlame {
                    Image(systemName: "flame.fill")
                }
                if !items.isEmpty {
                    Text(plainText)
                }
            }
        }
    }

    /// Plain text used when no color is involved.
    private var plainText: String {
        items.map { item in
            [item.prefixText, item.text].compactMap { $0 }.joined(separator: " ")
        }
        .joined(separator: " · ")
    }

    @MainActor
    private func rasterized() -> NSImage? {
        // The menu bar follows the system appearance; the automatic color is
        // resolved for it explicitly rather than for the app's own windows.
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: Color = isDark ? .white : .black
        let renderer = ImageRenderer(
            content: MenuBarLabelView(items: items, showsFlame: showsFlame, baseColor: base)
                .padding(.horizontal, 1)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }
}
