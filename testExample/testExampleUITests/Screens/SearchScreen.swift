import XCTest

/// Screen object for the Search tab.
///
/// Tests never touch raw queries — they speak in user intentions
/// (`search(for:)`) and observable facts (`row(for:)`). When the UI changes,
/// this file changes; the scenarios don't.
struct SearchScreen {
    let app: XCUIApplication

    var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    // Identified by its visible text rather than an accessibility
    // identifier: `ContentUnavailableView` re-parents a container-level
    // identifier onto every descendant it merges, so there's no reliable
    // container identifier to query by here. The heading text is stable and
    // honestly describes the state under test.
    var errorView: XCUIElement {
        app.staticTexts["Something went wrong"]
    }

    var retryButton: XCUIElement {
        app.buttons["search.retryButton"]
    }

    func search(for query: String) {
        searchField.tap()
        searchField.typeText(query)
    }

    func row(for fullName: String) -> XCUIElement {
        app.descendants(matching: .any)["search.row.\(fullName)"].firstMatch
    }

    func openDetail(for fullName: String) {
        row(for: fullName).tap()
    }
}
