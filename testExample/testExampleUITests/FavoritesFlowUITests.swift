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

    @MainActor
    func testDeletingAFavoriteViaEditButton() throws {
        // `EditButton`'s label and the "Delete" confirmation are both system
        // strings, so this scenario only runs in the development language —
        // see `skipUnlessRunningInEnglish(matching:)`.
        try skipUnlessRunningInEnglish(matching: "EditButton's \"Edit\" and the \"Delete\" confirmation")

        // Swipe-to-delete is a gesture, and a gesture is not an affordance:
        // it is invisible and unreachable for Switch Control and Voice
        // Control. `EditButton` gives the same operation a real control —
        // which is also the only version of it a UI test can drive without
        // synthesizing a partial swipe.
        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)
        let detail = RepoDetailScreen(app: app)
        let favorites = FavoritesScreen(app: app)

        Given("I have favorited apple/swift") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            search.search(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 5))
            search.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
            detail.toggleFavorite()
            favorites.open()
            XCTAssertTrue(favorites.row(for: "apple/swift").waitForExistence(timeout: 5))
        }

        When("I delete it with the Edit button") {
            favorites.deleteFirstRowInEditMode()
        }

        Then("the row is gone and the empty state is shown") {
            XCTAssertTrue(favorites.row(for: "apple/swift").waitForNonExistence(timeout: 5))
            XCTAssertTrue(favorites.emptyView.waitForExistence(timeout: 5))
        }

        And("the list itself is still there, so the delete could animate") {
            // The empty state is an *overlay* on a List that never goes away,
            // rather than a sibling view swapped in for it. Swapping destroyed
            // the List's identity, which is why deleting the last favorite
            // used to cut rather than animate.
            XCTAssertTrue(favorites.list.exists)
        }
    }
}
