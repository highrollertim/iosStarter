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
}
