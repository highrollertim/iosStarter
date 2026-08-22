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

    var errorView: XCUIElement {
        app.descendants(matching: .any)["search.errorView"].firstMatch
    }

    // The Retry button is declared with identifier "search.retryButton" in
    // the app, but `ContentUnavailableView` re-parents its accessibility
    // identifier onto every descendant it merges (including its action
    // button), so at runtime the button surfaces with identifier
    // "search.errorView" instead. Query by type + that identifier — it's
    // the only button among the several elements sharing it.
    var retryButton: XCUIElement {
        app.buttons["search.errorView"]
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
