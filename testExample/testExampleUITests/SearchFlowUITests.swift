import XCTest

final class SearchFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchingShowsResults() {
        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)

        Given("the app has launched to the Search tab") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"swift\"") {
            search.search(for: "swift")
        }

        Then("I see the apple/swift repository in the results") {
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testSearchFailureShowsRetryableError() {
        let app = XCUIApplication.launchedForUITest(scenario: "searchError")
        let search = SearchScreen(app: app)

        Given("the app has launched with GitHub rate-limiting searches") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"swift\"") {
            search.search(for: "swift")
        }

        Then("I see the error text instead of results") {
            XCTAssertTrue(search.errorView.waitForExistence(timeout: 5))
        }

        And("the retry button exists") {
            XCTAssertTrue(search.retryButton.waitForExistence(timeout: 5))
        }
    }
}
