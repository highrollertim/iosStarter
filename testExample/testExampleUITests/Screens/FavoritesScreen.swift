import XCTest

struct FavoritesScreen {
    let app: XCUIApplication

    var emptyView: XCUIElement {
        app.descendants(matching: .any)["favorites.emptyView"].firstMatch
    }

    var list: XCUIElement {
        app.descendants(matching: .any)["favorites.list"].firstMatch
    }

    /// UIKit's own `EditButton`, so its label is a *system* string —
    /// "Bearbeiten" under `-testLanguage de`. Locale-bound with no app-side
    /// fix, for the same reason as `SearchScreen.noResultsView`. Together
    /// with the "Delete" confirmation below, that view's system title, and
    /// `UISearchTextField`'s "Clear text" button, these are the last strings
    /// keeping any part of this suite in the development language — see
    /// `skipUnlessRunningInEnglish(matching:)`, which the one test that
    /// reaches this property calls first.
    var editButton: XCUIElement {
        app.navigationBars.buttons["Edit"]
    }

    /// Queried by identifier, which `Tab` carries onto the tab-bar button
    /// that selects it — so this survives `-testLanguage de`, where the tab
    /// reads "Favoriten".
    func open() {
        app.tabBars.buttons["tab.favorites"].tap()
    }

    func row(for fullName: String) -> XCUIElement {
        app.descendants(matching: .any)["favorites.row.\(fullName)"].firstMatch
    }

    func openDetail(for fullName: String) {
        row(for: fullName).tap()
    }

    /// Deletes a row through the `EditButton` affordance rather than a swipe:
    /// enter edit mode, tap the row's minus circle, confirm with Delete.
    ///
    /// The minus circle is matched as an *image* by its SF Symbol name and
    /// tapped by coordinate, because that is what the element tree actually
    /// contains: `List`'s edit-mode delete control is published as an
    /// `Image` labelled "remove", not as a button, and it sits beside the row
    /// element rather than inside it. Measured, not assumed — and re-measured
    /// after `RepoRowView` moved from `.combine` to `.ignore`, which changed
    /// nothing here: the control's representation is the `List`'s, not the
    /// row's, so no accessibility choice in `RepoRowView` can promote it to a
    /// button. `app.buttons` finds only the row itself, whose label edit mode
    /// prefixes with "Remove, ", so tapping that opens the detail screen
    /// instead of deleting.
    func deleteFirstRowInEditMode() {
        editButton.tap()
        let minusCircle = app.images["minus.circle.fill"].firstMatch
        XCTAssertTrue(minusCircle.waitForExistence(timeout: 5), "Edit mode never revealed a delete control")
        minusCircle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The confirmation button carries no identifier of ours — it is
        // UIKit's, so it is matched on its label.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Delete")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete confirmation never appeared")
        confirm.tap()
    }
}
