import AgentHearthCore
import Foundation
import XCTest

/// An empty status item has zero width, and macOS removes a zero-width item —
/// which for a `MenuBarExtra` app means terminating the process. These are the
/// cases in which the app disappeared from the menu bar.
@MainActor
final class MenuBarStatusLabelTests: XCTestCase {
    private func item(_ text: String) -> MenuBarRenderedItem {
        MenuBarRenderedItem(id: UUID(), text: text, tint: .automatic)
    }

    func testTheFlameDrawsWhenNothingElseWould() {
        let label = MenuBarStatusLabel(items: [], showsFlame: false)
        XCTAssertTrue(label.drawsFlame)
    }

    func testAConfiguredLayoutThatRendersToNothingStillDrawsTheFlame() {
        // At launch before the first snapshot, or once an item set to hide at
        // zero reaches zero: the layout is not empty, the rendering is.
        let label = MenuBarStatusLabel(items: [], showsFlame: false)
        XCTAssertTrue(label.drawsFlame)
    }

    func testTheFlameStaysHiddenOnceThereIsSomethingToDraw() {
        let label = MenuBarStatusLabel(items: [item("3")], showsFlame: false)
        XCTAssertFalse(label.drawsFlame)
    }

    func testTheFlameIsKeptWhenItWasAskedFor() {
        let label = MenuBarStatusLabel(items: [item("3")], showsFlame: true)
        XCTAssertTrue(label.drawsFlame)
    }
}
