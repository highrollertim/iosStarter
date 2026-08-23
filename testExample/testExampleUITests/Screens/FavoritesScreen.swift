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
    /// fix, for the same reason as `SearchScreen.noResultsView`.
    var editButton: XCUIElement {
        app.navigationBars.buttons["Edit"]
    }

    /// Queried by its localized title because there is no alternative: `Tab`
    /// is a builder for a tab's *content*, not a `View`, so
    /// `.accessibilityIdentifier` applied to it decorates the screen inside
    /// the tab rather than the tab-bar button that selects it. SwiftUI
    /// exposes no API to identify that button, so a localized-string query is
    /// the honest option.
    ///
    /// Measured, not assumed: under `-testLanguage de` this fails with
    /// *No matches found for … '"Favorites" IN identifiers'*, because the tab
    /// now reads "Favoriten". Together with `editButton` and the "Delete"
    /// confirmation below, that is why the German verification run covers
    /// `LaunchTests` only.
    func open() {
        app.tabBars.buttons["Favorites"].tap()
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
    /// The minus circle is tapped via its own coordinate rather than
    /// `row(for:).tap()` because `RepoRowView` merges itself into a single
    /// accessibility element (`.accessibilityElement(children: .combine)`).
    /// In edit mode that merged element covers the whole row — it reports as
    /// one button labelled "Remove, apple/swift, …" — so tapping it hits the
    /// row content, not the control. The minus circle is still present as its
    /// own hittable image, identified by its SF Symbol name, and that is what
    /// a sighted user's finger actually lands on.
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
