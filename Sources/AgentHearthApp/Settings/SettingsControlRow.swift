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
    .padding(.vertical, 1)
}
