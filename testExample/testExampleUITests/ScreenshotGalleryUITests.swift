import XCTest

/// Captures the images the README shows, from the running app.
///
/// A screenshot in a README rots the moment the UI moves, and the usual
/// remedy — someone remembering to re-take it — is not a remedy. Producing
/// them from the UI suite means they are taken by the same hermetic launch
/// (`-UITestMockNetwork`, `-UITestInMemoryStore`) that every other test uses,
/// against the same fixture repositories, so re-running one command
/// regenerates the whole gallery from the current build. They are
/// `XCTAttachment`s with `.keepAlways` lifetime, so they survive into the
/// result bundle even though the tests pass; `xcrun xcresulttool export
/// attachments` lifts them back out. The exact commands are in the README
/// section these images head.
///
/// **English only, and deliberately so.** These are asserted-on-nothing
/// captures whose *purpose* is a specific language, and the German one sets
/// its own language on the launch below. Running the pair again under the test
/// plan's German configuration would spend a minute of every CI run producing
/// a second, redundant set — so both methods open with the same gate the other
/// language-bound tests use. That gate is about which *configuration* is
/// running, not about what these tests can see: the German capture below
/// happens inside the English run.
///
/// These tests assert only that the app reached the screen being photographed.
/// That is the honest scope: an unreadable or empty screenshot fails here, but
/// nothing about the *appearance* of a correct one is checked by anything but
/// a human looking at the README.
final class ScreenshotGalleryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCapturesTheEnglishGallery() throws {
        try skipUnlessRunningInEnglish(matching: "the README's English screenshots")

        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)
        let detail = RepoDetailScreen(app: app)
        let favorites = FavoritesScreen(app: app)

        Given("results for \"swift\" are on screen") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            // Submitted rather than merely typed: Return dismisses the
            // keyboard, and a keyboard covering the bottom half of the frame is
            // not a picture of the results list.
            search.searchAndSubmit(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 10))
        }

        Then("the search results are captured") {
            attach(app.screenshot(), named: "01-search-results")
        }

        When("I open apple/swift") {
            search.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
        }

        Then("the detail screen is captured") {
            attach(app.screenshot(), named: "02-repo-detail")
        }

        When("I favorite it and switch to the Favorites tab") {
            detail.toggleFavorite()
            favorites.open()
            XCTAssertTrue(favorites.row(for: "apple/swift").waitForExistence(timeout: 5))
        }

        Then("the populated Favorites tab is captured") {
            attach(app.screenshot(), named: "03-favorites")
        }
    }

    @MainActor
    func testCapturesTheGermanSearchResults() throws {
        try skipUnlessRunningInEnglish(matching: "the README's screenshots")

        // The app's own language, set on the launch rather than by the test
        // plan: this capture has to happen in the English configuration (see
        // the type comment), so it cannot inherit German from the run. These
        // are the same two defaults `xcodebuild -testLanguage` writes, and the
        // reason the screenshot is worth having at all — the German column of
        // the README is the only place the localization is visible to someone
        // who is not running the suite.
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestMockNetwork", "-UITestInMemoryStore",
            "-AppleLanguages", "(de)",
            "-AppleLocale", "de_DE",
        ]
        app.launchEnvironment["UITEST_SCENARIO"] = "success"
        app.launch()

        let search = SearchScreen(app: app)

        Given("the app has launched in German") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
        }

        When("I search for \"swift\"") {
            search.searchAndSubmit(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 10))
        }

        Then("the German results screen is captured") {
            attach(app.screenshot(), named: "04-search-results-de")
        }
    }

    /// `.keepAlways`, because the default (`.deletedWhenEntirelySuccessful`)
    /// throws away exactly the attachments this suite exists to produce.
    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
