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
    func testSearchWithNoMatchesShowsTheNoResultsState() throws {
        // The assertion below matches `ContentUnavailableView.search(text:)`'s
        // own title, which Apple localizes — see
        // `skipUnlessRunningInEnglish(matching:)`.
        try skipUnlessRunningInEnglish(matching: "ContentUnavailableView.search(text:)'s \"No Results\" title")

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
        //
        // `searchErrorOnce` fails the first completed search per *query*, so
        // this scenario does not depend on typing speed: the prefix emissions
        // that "swift" produces on the way in each get their own failure and
        // cannot consume the one this test is waiting for.
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
            // Bounded retry rather than a single wait. `searchErrorOnce` fails
            // the first *completed* call per query, and typing "swift"
            // produces prefix queries too — a slow enough typist gets a prefix
            // failure on screen, and the Retry the test taps re-runs that
            // prefix rather than "swift", which then has its own first failure
            // still to spend. Each further tap consumes one more, so a handful
            // of attempts converges. The assertion after the loop is the real
            // one; the loop only stops the test from depending on how fast the
            // simulator types.
            for _ in 1...3 where !search.row(for: "apple/swift").exists {
                if search.retryButton.exists { search.retryButton.tap() }
                _ = search.row(for: "apple/swift").waitForExistence(timeout: 10)
            }
            XCTAssertTrue(search.row(for: "apple/swift").exists)
            XCTAssertFalse(search.errorView.exists)
        }
    }

    @MainActor
    func testAFailedRefreshKeepsTheResultsAndItsRetryKeepsThemToo() {
        // The state no other UI test reaches: a failure *with results still on
        // screen*. It is the whole reason `LoadState.failed` carries `stale`,
        // and the reason the list is hoisted out of the state switch — one
        // list identity across `.loaded` and `.failed(_, stale:)`, so the rows
        // are updated rather than destroyed and rebuilt.
        //
        // `searchSucceedsThenFails` succeeds the first completed call for each
        // query and fails every later one for that same query. So the first
        // search populates the list, and every submission after it — including
        // the one the Retry button makes — fails. That makes the terminal
        // assertion a strong one rather than a lucky one: the banner comes
        // back, and the rows are still underneath it.
        let app = XCUIApplication.launchedForUITest(scenario: "searchSucceedsThenFails")
        let search = SearchScreen(app: app)

        Given("I have results on screen") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            search.searchAndSubmit(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 10))
            XCTAssertFalse(search.errorView.exists)
        }

        When("I re-run the same search until it fails") {
            // Bounded, for the same reason as the retry loop above: the rows
            // on screen may have come from a prefix query, and a submission
            // that is cancelled before the mock's sleep returns never counts
            // as a completed call. Each further submission adds one that does.
            for _ in 1...3 where !search.errorView.exists {
                search.submitAgain()
                _ = search.errorView.waitForExistence(timeout: 6)
            }
        }

        Then("the rows stay, under a banner offering a retry") {
            XCTAssertTrue(search.errorView.waitForExistence(timeout: 10))
            XCTAssertTrue(search.list.exists)
            XCTAssertTrue(search.row(for: "apple/swift").exists)
            XCTAssertTrue(search.retryButton.exists)
        }

        When("I tap Retry in the banner") {
            search.retryButton.tap()
        }

        Then("the rows never left, and the second failure keeps them too") {
            // Immediately: the retry promotes the stale rows back to a
            // refreshing `.loaded`, so the list is still on screen with its
            // rows while the request is in flight. When the failure lands, the
            // banner returns over the same rows.
            XCTAssertTrue(search.row(for: "apple/swift").exists)
            XCTAssertTrue(search.errorView.waitForExistence(timeout: 10))
            XCTAssertTrue(search.row(for: "apple/swift").exists)
        }
    }
}
