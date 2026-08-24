import XCTest

/// The one place that knows why this suite's German run is partial.
///
/// `testExample.xctestplan` has two configurations, English and German, so
/// every invocation of the suite runs twice — the German pass is the app's
/// localization smoke check. Almost all of it is locale-independent already:
/// screens are matched by accessibility identifier, including the tab-bar
/// buttons and the search screen's error text. Three assertions are not, and
/// cannot be, because they match strings **Apple** owns and translates:
///
/// - `ContentUnavailableView.search(text:)`'s "No Results" title,
/// - `EditButton`'s "Edit" and the "Delete" confirmation it leads to,
/// - `UISearchTextField`'s "Clear text" button — matched only to *suppress*
///   an unfixable hit-region issue in the accessibility audit, which means a
///   German run fails the audit rather than skipping a query.
///
/// The alternatives are abandoning the system views that make those screens
/// correct, or hard-coding a translation table of Apple's own strings that
/// would be wrong the next time Apple rewords one. Declaring the dependency
/// is the honest third option, and `XCTSkip` reports it in the result bundle
/// instead of hiding it.
///
/// **Why this is a runtime gate and not test-plan configuration.** A test
/// plan configuration carries `language` and `region` but *not* per-
/// configuration test selection: a `skippedTests` array inside a
/// configuration's `options` is accepted by the file format and then ignored.
/// Measured, not assumed — a unit test listed there ran in both
/// configurations anyway. Test selection in a plan is per *target*, and a
/// target-level skip would remove these tests from the English run too, which
/// is the run they exist for.
///
/// - Parameter subject: what the test matches that Apple owns, named in the
///   skip message so the result bundle explains itself.
func skipUnlessRunningInEnglish(
    matching subject: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let language = currentTestLanguage
    try XCTSkipUnless(
        language == "en",
        """
        Runs in the development language only: this test matches \(subject), \
        a system string Apple localizes. Current language: \(language ?? "unknown").
        """,
        file: file,
        line: line
    )
}

/// The language code of the test-plan configuration currently running, as the
/// app and the runner both see it.
///
/// Factored out because there are now two *different* reasons to run
/// English-only, and only one of them is the Apple-owned-string problem above.
/// `ScreenshotGalleryUITests` gates on the same fact for a reason of its own —
/// its captures are for an English README, and the German one sets its own
/// language — so it needs the check without the message that comes with it.
/// One place computes it; each caller says why it cares.
var currentTestLanguage: String? {
    Locale.current.language.languageCode?.identifier
}
