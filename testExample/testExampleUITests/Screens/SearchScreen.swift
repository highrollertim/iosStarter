import XCTest

/// Screen object for the Search tab.
///
/// Tests never touch raw queries — they speak in user intentions
/// (`search(for:)`) and observable facts (`row(for:)`). When the UI changes,
/// this file changes; the scenarios don't.
struct SearchScreen {
    let app: XCUIApplication

    /// Queried by element type, not by accessibility identifier: `.searchable`
    /// builds and owns the search field itself and exposes no API to identify
    /// it, so `.accessibilityIdentifier` applied around the modifier lands on
    /// the *content* rather than the field. There is exactly one search field
    /// on this screen, which makes the type query unambiguous anyway.
    var searchField: XCUIElement {
        app.searchFields.firstMatch
    }

    /// The error state's description text, identified rather than read.
    ///
    /// This used to match the literal string "Something went wrong", which
    /// worked exactly as long as the app had one language. `SearchView` now
    /// puts `search.errorView` on the description `Text` itself — not on the
    /// `ContentUnavailableView`, whose container identifier gets re-parented
    /// onto its merged children — so this query survives `-testLanguage de`.
    var errorView: XCUIElement {
        app.descendants(matching: .any)["search.errorView"].firstMatch
    }

    /// `ContentUnavailableView.search(text:)` renders its title as
    /// `No Results for “swift”` — the query is interpolated, with typographic
    /// quotes that vary by locale. Matched by prefix so the assertion tests
    /// the *state*, not the app's choice of quotation marks.
    ///
    /// **This query is locale-bound and there is no app-side fix.** The title
    /// is a *system* string owned by `ContentUnavailableView.search(text:)`;
    /// under `-testLanguage de` it reads "Keine Ergebnisse für …" and this
    /// predicate finds nothing. The only ways out are to stop using the
    /// system's empty-search view (losing the reason it is here) or to
    /// hard-code a translation table of Apple's own strings, which would be
    /// wrong the next time Apple rewords it. The suite is therefore written
    /// to run in the development language; the German run is a localization
    /// smoke check (see `LaunchTests`), not a full-suite target.
    var noResultsView: XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "No Results"))
            .firstMatch
    }

    var retryButton: XCUIElement {
        app.buttons["search.retryButton"]
    }

    func search(for query: String) {
        searchField.tap()
        // `tap()` returns once the event has been delivered, not once the
        // field has taken focus and the keyboard is up. Typing into a
        // not-yet-focused field silently drops the leading characters — the
        // classic source of a suite that fails one run in twenty having
        // searched for "wift".
        //
        // Note for CI images and fresh machines: this waits on the *software*
        // keyboard, which never appears while Simulator ▸ I/O ▸ Keyboard ▸
        // "Connect Hardware Keyboard" is enabled. If this assertion is the
        // thing failing, that setting is almost certainly why.
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 15),
            "Software keyboard never appeared; check Simulator ▸ I/O ▸ Keyboard ▸ Connect Hardware Keyboard is off"
        )
        searchField.typeText(query)
    }

    /// Presses Return, which submits the query immediately (bypassing the
    /// debounce — see `SearchViewModel.submitImmediately()`) and dismisses the
    /// keyboard. Tests that need the results list unobscured use this.
    func submit() {
        searchField.typeText("\n")
    }

    func row(for fullName: String) -> XCUIElement {
        app.descendants(matching: .any)["search.row.\(fullName)"].firstMatch
    }

    func openDetail(for fullName: String) {
        row(for: fullName).tap()
    }
}
