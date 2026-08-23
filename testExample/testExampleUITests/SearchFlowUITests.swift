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
    func testSearchWithNoMatchesShowsTheNoResultsState() {
        // A *successful* search that matched nothing. No error scenario
        // reaches this screen — `.loaded([])` is its own branch in
        // `SearchView` — so without a dedicated mock scenario the empty state
        // shipped entirely untested.
        let app = XCUIApplication.launchedForUITest(scenario: "emptyResults")
        let search = SearchScreen(app: app)

        Given("the app has launched against a GitHub with nothing to find") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"zzzz\"") {
            search.search(for: "zzzz")
        }

        Then("I see the no-results state rather than an empty list") {
            XCTAssertTrue(search.noResultsView.waitForExistence(timeout: 5))
            XCTAssertFalse(search.errorView.exists)
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

    @MainActor
    func testRetryRecoversFromATransientFailure() {
        // The existing failure test only proves the Retry button is *there*.
        // This one proves it works — which is the part that was broken:
        // `removeDuplicates()` used to swallow the re-submitted query, so a
        // failed search could not be repeated at all.
        let app = XCUIApplication.launchedForUITest(scenario: "searchErrorOnce")
        let search = SearchScreen(app: app)

        Given("the first search will fail and later ones will succeed") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"swift\"") {
            search.search(for: "swift")
        }

        Then("I see the retryable error") {
            XCTAssertTrue(search.retryButton.waitForExistence(timeout: 5))
        }

        When("I tap Retry") {
            search.retryButton.tap()
        }

        Then("the results appear") {
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 10))
            XCTAssertFalse(search.errorView.exists)
        }
    }
}
