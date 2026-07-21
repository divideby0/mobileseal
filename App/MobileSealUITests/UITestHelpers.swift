import XCTest

extension XCUIApplication {
    /// Opens the gallery's More menu and taps the item whose label
    /// matches (exactly, or by prefix for dynamic labels). Menu items
    /// are matched by LABEL — SwiftUI does not propagate
    /// accessibility identifiers onto menu items — and the UI-test
    /// seams (Import Fixtures / Seed 500) live inside this menu so
    /// the toolbar never collapses into a system overflow.
    @discardableResult
    func tapMoreMenuItem(
        label: String, prefixMatch: Bool = false, timeout: TimeInterval = 15
    ) -> Bool {
        let more = buttons.matching(
            NSPredicate(format: "identifier == 'more-menu-button' OR label == 'More'")
        ).firstMatch
        guard more.waitForExistence(timeout: timeout) else { return false }
        more.tap()
        let predicate =
            prefixMatch
            ? NSPredicate(format: "label BEGINSWITH %@", label)
            : NSPredicate(format: "label == %@", label)
        let item = buttons.matching(predicate).firstMatch
        guard item.waitForExistence(timeout: 10) else { return false }
        item.tap()
        return true
    }
}
