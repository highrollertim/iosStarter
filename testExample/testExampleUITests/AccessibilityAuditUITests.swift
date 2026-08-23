import XCTest

/// Runs XCTest's built-in accessibility audit over the app's main screens.
///
/// `performAccessibilityAudit()` is the cheapest accessibility coverage
/// available: it walks the live element tree and flags contrast failures,
/// undersized hit regions, text likely to clip at large Dynamic Type sizes,
/// elements with no description, and mislabelled traits. It is not a
/// substitute for using the app with VoiceOver — it cannot tell you that a
/// label is *wrong*, only that one is missing — but it catches the mechanical
/// regressions that otherwise ship, and it costs one test.
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
    /// The label is matched in English, which is what this suite runs in. A
    /// localized run would need the localized string — an awkwardness that is
    /// itself a good argument for keeping this list at one entry.
    @MainActor
    private static func ignoringSearchFieldClearButton(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.auditType == .hitRegion && issue.element?.label == "Clear text"
    }

    /// The above, plus `.textClipped`.
    ///
    /// The audit's clipping check is a *static* heuristic: it measures an
    /// element at the current text size and predicts whether the same layout
    /// would overflow at a larger one. `RepoRowView` answers that question at
    /// runtime instead, with `ViewThatFits` — the stats row reflows from an
    /// `HStack` to a `VStack` when it stops fitting — and the heuristic
    /// cannot see a layout that has not been proposed yet. So it flags the
    /// star count at default size for a clip that never happens.
    ///
    /// Verified, not assumed: see
    /// `testSearchResultsSurviveTheLargestDynamicTypeSize()`, which runs the
    /// same audit at AX5 with this suppression removed, and passes.
    @MainActor
    private static func ignoringKnownFalsePositives(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        ignoringSearchFieldClearButton(issue) || issue.auditType == .textClipped
    }
}
