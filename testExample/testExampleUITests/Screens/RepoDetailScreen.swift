import XCTest

struct RepoDetailScreen {
    let app: XCUIApplication

    var favoriteButton: XCUIElement {
        app.buttons["detail.favoriteButton"]
    }

    func toggleFavorite() {
        favoriteButton.tap()
    }

    func goBack() {
        app.navigationBars.buttons.firstMatch.tap()
    }
}
