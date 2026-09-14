import SwiftUI

/// A labeled settings row with a right-aligned control, shared by every
/// Settings section so column widths stay consistent.
func settingsControlRow<Control: View>(
    _ title: String,
    @ViewBuilder control: () -> Control
) -> some View {
    HStack(alignment: .center, spacing: 16) {
        Text(title)
            .frame(minWidth: 185, alignment: .leading)

        Spacer(minLength: 20)

        control()
            .frame(width: 210, alignment: .trailing)
    }
    .frame(maxWidth: .infinity)
    // One point of padding reads as rows touching each other; four is enough
    // to separate them without turning a dense settings pane into a scroll.
    .padding(.vertical, 4)
}
