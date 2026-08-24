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
    /// wrong the next time Apple rewords it. Its one caller therefore opens
    /// with `skipUnlessRunningInEnglish(matching:)`, so the test plan's
    /// German configuration reports it as skipped instead of failing on a
    /// string this app does not own.
    var noResultsView: XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "No Results"))
            .firstMatch
    }

    var retryButton: XCUIElement {
        app.buttons["search.retryButton"]
    }

    /// Selects the Search tab, matching `FavoritesScreen.open()`.
    ///
    /// Queried by identifier, which `Tab` carries onto the tab-bar button that
    /// selects it — so this survives `-testLanguage de`, where the tab reads
    /// "Suchen". The one test that used to reach for `app.tabBars` inline was
    /// the only place in the suite that named a raw query outside a screen
    /// object, which is exactly the leak these types exist to stop.
    func open() {
        app.tabBars.buttons["tab.search"].tap()
    }

    func search(for query: String) {
        focusField()
        searchField.typeText(query)
    }

    /// Presses Return, which submits the query immediately (bypassing the
    /// debounce — see `SearchViewModel.submitImmediately()`) and dismisses the
    /// keyboard. Tests that need the results list unobscured use this.
    func submit() {
        searchField.typeText("\n")
    }

    /// Types the query and its Return in a single `typeText`.
    ///
    /// This narrows — it does not close — the window in which the debounce
    /// fires a search of its own for the same text before the Return arrives.
    /// Nothing here can close it: how fast the simulator types is not
    /// something a test controls, which is why the scenarios that *count*
    /// searches key their bookkeeping per query, and why the tests using them
    /// are written to hold whichever way that race lands.
    func searchAndSubmit(for query: String) {
        focusField()
        searchField.typeText(query + "\n")
    }

    /// Re-submits whatever is already in the field, re-focusing it first.
    ///
    /// A previous `submit()` dismissed the keyboard, and `typeText` on an
    /// unfocused field goes nowhere.
    func submitAgain() {
        focusField()
        submit()
    }

    private func focusField() {
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
    }

    /// The results list itself, which is one view across `.loaded` and
    /// `.failed(_, stale:, _)` — the same element, updated, not two lists that
    /// take turns.
    var list: XCUIElement {
        app.descendants(matching: .any)["search.list"].firstMatch
    }

    func row(for fullName: String) -> XCUIElement {
        app.descendants(matching: .any)["search.row.\(fullName)"].firstMatch
    }

    func openDetail(for fullName: String) {
        row(for: fullName).tap()
    }
}
