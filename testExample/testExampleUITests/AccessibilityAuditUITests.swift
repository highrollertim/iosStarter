import XCTest

/// Runs XCTest's built-in accessibility audit over the app's main screens.
///
/// `performAccessibilityAudit()` is the cheapest accessibility coverage
/// available: it walks the live element tree and flags contrast failures,
/// undersized hit regions, text likely to clip at large Dynamic Type sizes,
/// elements with no description, and mislabelled traits. It is not a
/// substitute for using the app with VoiceOver — it cannot tell you that a
/// label is *wrong*, only that one is missing — but it catches the mechanical
/// regressions that otherwise ship, and it costs one method call per screen.
///
/// It earned its place immediately: it caught `RepoRowView`'s `.secondary`
/// text sitting below the WCAG AA contrast threshold at every size in the
/// row, which no amount of looking at the screen had noticed.
final class AccessibilityAuditUITests: XCTestCase {

    /// The largest Dynamic Type size iOS offers. If the layout survives this,
    /// it survives anything a user can ask for.
    private static let largestAccessibilitySize =
        "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchResultsAndFavoritesPassTheAccessibilityAudit() throws {
        try skipUnlessRunningInEnglish(matching: "UISearchTextField's \"Clear text\" button")

        let app = XCUIApplication.launchedForUITest()
        let search = SearchScreen(app: app)
        let detail = RepoDetailScreen(app: app)
        let favorites = FavoritesScreen(app: app)

        Given("I am looking at search results with the keyboard dismissed") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            search.search(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 5))
            // Submitting dismisses the keyboard. This matters: an on-screen
            // keyboard puts dozens of *system* elements into the audit's
            // scope — the emoji category strip and the predictive-text bar
            // both fail the hit-region and description checks — and drowns
            // the app's own results in noise no app can fix.
            search.submit()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        }

        try Then("the search screen has no accessibility issues of our making") {
            try app.performAccessibilityAudit(Self.ignoringKnownFalsePositives)
        }

        When("I favorite a repository and open the Favorites tab") {
            search.openDetail(for: "apple/swift")
            XCTAssertTrue(detail.favoriteButton.waitForExistence(timeout: 5))
            detail.toggleFavorite()
            favorites.open()
            XCTAssertTrue(favorites.row(for: "apple/swift").waitForExistence(timeout: 5))
        }

        try Then("the favorites screen has no accessibility issues either") {
            try app.performAccessibilityAudit(Self.ignoringKnownFalsePositives)
        }
    }

    /// The screen the two audits above cannot reach: results with a failure
    /// banner over them.
    ///
    /// It is worth its own launch because it is the only state that puts a
    /// *control* in the safe-area bar. Everything else down there is ambient
    /// status the footer hides from assistive technology; the banner is the
    /// opposite — a message the user is meant to read and a button they are
    /// meant to hit — so it is exactly the thing the audit's description and
    /// hit-region checks exist for.
    @MainActor
    func testTheFailureBannerOverResultsPassesTheAccessibilityAudit() throws {
        try skipUnlessRunningInEnglish(matching: "UISearchTextField's \"Clear text\" button")

        let app = XCUIApplication.launchedForUITest(scenario: "searchSucceedsThenFails")
        let search = SearchScreen(app: app)

        Given("I am looking at results with a failure banner over them") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 5))
            search.searchAndSubmit(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 10))
            for _ in 1...3 where !search.errorView.exists {
                search.submitAgain()
                _ = search.errorView.waitForExistence(timeout: 6)
            }
            XCTAssertTrue(search.errorView.exists)
            // Same reason as the test above: an on-screen keyboard fills the
            // audit with system elements no app can fix.
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        }

        try Then("the banner and the rows under it have no issues of our making") {
            try app.performAccessibilityAudit(Self.ignoringKnownFalsePositives)
        }
    }

    /// The audit again, at the largest accessibility text size — and this time
    /// **without** suppressing `.textClipped`.
    ///
    /// This test is the evidence behind the suppression in the test above.
    /// Suppressing a warning on the strength of a comment is how warnings
    /// become permanently wrong; suppressing one because a second test checks
    /// the thing it was warning about is how you keep the signal. If
    /// `RepoRowView`'s `ViewThatFits` ever stops rescuing the layout at
    /// accessibility sizes, this fails even though the default-size test
    /// still passes.
    @MainActor
    func testSearchResultsSurviveTheLargestDynamicTypeSize() throws {
        try skipUnlessRunningInEnglish(matching: "UISearchTextField's \"Clear text\" button")

        let app = XCUIApplication.launchedForUITest(
            contentSizeCategory: Self.largestAccessibilitySize
        )
        let search = SearchScreen(app: app)

        Given("the app is running at the largest accessibility text size") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 15))
            search.search(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 15))
            search.submit()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        }

        try Then("nothing clips and nothing else regresses") {
            try app.performAccessibilityAudit(Self.ignoringSearchFieldClearButton)
        }
    }

    /// The banner screen at the largest accessibility text size, with
    /// `.textClipped` **not** suppressed.
    ///
    /// The test above does this for the results list; this does it for the one
    /// screen the list test cannot reach, and it is the harder of the two. The
    /// banner puts a sentence-long message and a `Retry` button on one line;
    /// at AX5 there is nowhere near room for both, and a control whose title
    /// has truncated to "Ret…" no longer says what it does. `ErrorBanner`
    /// answers that at runtime with `ViewThatFits`, exactly as
    /// `RepoRowView.stats` does — and, exactly as there, the audit's static
    /// clipping heuristic cannot see a layout that has not been proposed yet.
    /// So this test is what makes the `.textClipped` suppression on
    /// `testTheFailureBannerOverResultsPassesTheAccessibilityAudit()` honest:
    /// if the reflow ever stops rescuing the banner, this fails.
    @MainActor
    func testTheFailureBannerSurvivesTheLargestDynamicTypeSize() throws {
        try skipUnlessRunningInEnglish(matching: "UISearchTextField's \"Clear text\" button")

        let app = XCUIApplication.launchedForUITest(
            scenario: "searchSucceedsThenFails",
            contentSizeCategory: Self.largestAccessibilitySize
        )
        let search = SearchScreen(app: app)

        Given("the failure banner is on screen at the largest accessibility text size") {
            XCTAssertTrue(search.searchField.waitForExistence(timeout: 15))
            search.searchAndSubmit(for: "swift")
            XCTAssertTrue(search.row(for: "apple/swift").waitForExistence(timeout: 15))
            // Same loop as the default-size banner test: the first completed
            // search for a query succeeds and every later one fails, but which
            // debounce emission completes first is not something a test
            // controls, so re-submit until the banner is actually up.
            for _ in 1...3 where !search.errorView.exists {
                search.submitAgain()
                _ = search.errorView.waitForExistence(timeout: 6)
            }
            XCTAssertTrue(search.errorView.exists)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        }

        try Then("the banner reflows instead of clipping, and nothing else regresses") {
            try app.performAccessibilityAudit(Self.ignoringSearchFieldClearButton)
        }
    }

    // MARK: - Issue filters
    //
    // Each returns `true` to suppress an issue and `false` to let it fail the
    // test. Both suppression lists are deliberately tiny; an audit you have
    // taught to ignore things is only worth having if you can still say
    // exactly what it ignores and why.

    /// Suppresses UIKit's own "Clear text" button inside the `.searchable`
    /// field, which measures roughly 20×19pt against the audit's 44×44pt
    /// minimum. The button is built and laid out by `UISearchTextField` and
    /// `.searchable` exposes no hook to resize or replace it, so the
    /// alternatives are abandoning `.searchable` for a hand-rolled field or
    /// letting a permanently unfixable issue fail the suite.
    ///
    /// The label is matched in English. Every test in this class therefore
    /// opens with `skipUnlessRunningInEnglish(matching:)`: under the test
    /// plan's German configuration the same button is "Text löschen", this
    /// filter stops matching, and the audit fails on an issue no app-side
    /// change can fix. Needing a translation table to keep a suppression
    /// working is itself a good argument for keeping this list at one entry.
    @MainActor
    private static func ignoringSearchFieldClearButton(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.auditType == .hitRegion && issue.element?.label == "Clear text"
    }

    /// The above, plus `.textClipped`.
    ///
    /// The audit's clipping check is a *static* heuristic: it measures an
    /// element at the current text size and predicts whether the same layout
    /// would overflow at a larger one. `RepoRowView` and `ErrorBanner` both
    /// answer that question at runtime instead, with `ViewThatFits` — the
    /// stats row and the banner each reflow from an `HStack` to a `VStack`
    /// when they stop fitting — and the heuristic cannot see a layout that has
    /// not been proposed yet. So it flags the star count, and the banner's
    /// message and button, at default size for clips that never happen.
    ///
    /// Verified per layout, not assumed, and that is why there are two AX5
    /// tests rather than one. Each runs the *same* audit at AX5 with
    /// `.textClipped` back in play:
    /// `testSearchResultsSurviveTheLargestDynamicTypeSize()` covers the
    /// results list, and `testTheFailureBannerSurvivesTheLargestDynamicTypeSize()`
    /// covers the banner over it. Those are the two reflowing layouts this
    /// filter forgives, and neither is now suppressed on nothing but this
    /// paragraph's say-so.
    ///
    /// What is *not* separately witnessed at AX5 is the Favorites screen,
    /// audited with this filter by the first test in the class. Its rows are
    /// `RepoRowView`, so the flagged element and the `ViewThatFits` that
    /// rescues it are literally the same code the results list exercises —
    /// but "the same view type" is an argument, not a measurement, and the
    /// screen around it (an `EditButton`, a swipe-to-delete affordance) is
    /// not. It is on the guide's known-edges list for that reason.
    @MainActor
    private static func ignoringKnownFalsePositives(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        ignoringSearchFieldClearButton(issue) || issue.auditType == .textClipped
    }
}
