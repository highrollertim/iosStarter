import XCTest

final class FavoritesFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFavoritingARepoRoundTrip() {
        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)
        let detail = RepoDetailScreen(app: app)
        let favorites = FavoritesScreen(app: app)

        Given("I have searched for \"swift\" and opened apple/swift") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            search.search(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 5))
            search.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
        }

        When("I favorite the repository") {
            detail.toggleFavorite()
        }

        Then("it appears in the Favorites tab") {
            favorites.open()
            XCTAssertTrue(favorites.row(for: "apple/swift").waitForExistence(timeout: 5))
        }

        When("I unfavorite it from its detail screen") {
            favorites.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
            detail.toggleFavorite()
            detail.goBack()
        }

        Then("the Favorites tab shows its empty state") {
            XCTAssertTrue(favorites.emptyView.waitForExistence(timeout: 5))
        }
    }
}
