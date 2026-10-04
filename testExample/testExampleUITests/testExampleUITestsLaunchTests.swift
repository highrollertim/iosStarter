import XCTest

/// Smoke test: the app launches at all, once per test-plan language, and we
/// keep a screenshot in the result bundle. The appearance-and-orientation
/// matrix described below is opt-in.
///
/// Two independent multipliers apply here, and they are worth telling apart —
/// the result bundle is confusing until you do.
///
/// `runsForEachTargetApplicationUIConfiguration` makes XCTest repeat the run
/// across combinations of appearance, the app's supported localizations, and
/// orientation. Measured, not assumed — running just `testLaunch` with
/// `-resultBundlePath` and reading the argument nodes back with
/// `xcrun xcresulttool get test-results tests` gives eight per configuration,
/// labelled "Light Appearance, English, Portrait", "Light Appearance, German,
/// Portrait Upside Down", ", , Landscape Right" and the like.
///
/// Read the orientation half of those labels carefully, because it is the
/// part that surprises. This app's Info.plist declares Portrait, Landscape
/// Left and Landscape Right — **not** `UIInterfaceOrientationPortraitUpsideDown`
/// — and the matrix names Portrait Upside Down anyway. The axis is derived
/// from what the *device* can do, not from what the app says it supports, so a
/// configuration can be labelled with an orientation the app will never
/// actually rotate into: the app simply stays put and the screenshot is of the
/// orientation it kept. Worth knowing before reading a bundle and concluding
/// the app's supported-orientation list is wrong.
///
/// The test plan's two *configurations* are a separate axis, and a stronger
/// one: they relaunch the app under `de`/`DE` for real, which is what makes
/// the German pass a localization check rather than a metadata permutation.
/// So these screenshots span both, and this class is the app's launch smoke
/// test and its most direct German one at the same time.
///
/// The matrix is **off by default**, and the reason is measured rather than
/// assumed, in the same units as above: eight configurations per language,
/// so sixteen across the plan's two configurations. The override is
/// class-level, so it multiplied both tests here: sixteen launch-and-
/// terminate cycles of `testLaunch`, and sixteen runs of
/// `testLaunchPerformance`, each of which is `measure`'s five iterations
/// plus a warm-up, so roughly a hundred further launches. With it on, this
/// class was thirteen minutes of a thirty-two-minute UI job on a hosted
/// macOS runner, and the one test that failed there: `app.launch()` first
/// terminates the previous instance, a loaded shared simulator took longer
/// than XCTest's sixty-second allowance to do it, and one of the eight
/// English `testLaunch` configurations reported "Failed to terminate" while
/// the other seven and the whole German pass were green. A smoke test that
/// is the most expensive and the least reliable test in the suite is the
/// wrong shape for a gate.
///
/// What the matrix proved is still proved: the app launches in both
/// languages because the test plan runs this class twice, and the
/// appearance and orientation screenshots are a nice-to-have the result
/// bundle can carry when someone asks for them. The switch is an environment
/// variable rather than an edit to this file, so turning the gallery on for
/// one local run cannot be committed by accident:
///
///     TEST_RUNNER_UI_CONFIG_MATRIX=1 xcodebuild test ... -only-testing:testExampleUITests/LaunchTests
///
/// (`xcodebuild` forwards `TEST_RUNNER_`-prefixed variables to the test
/// runner with the prefix stripped; the Xcode scheme editor's test
/// environment does the same without the prefix.)
final class LaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        ProcessInfo.processInfo.environment["UI_CONFIG_MATRIX"] == "1"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        // The same hermetic launch every other test here uses, rather than a
        // hand-rolled copy of its arguments: one definition of "launched for
        // a UI test" means a new launch argument reaches every test at once.
        let app = XCUIApplication.launchedForUITest()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launch time is a user-visible feature and the easiest thing in an app
    /// to regress by accident — one eager `ModelContainer`, one synchronous
    /// file read in the composition root, and it is gone. `measure` with
    /// `XCTApplicationLaunchMetric` records it per run, so the number lives in
    /// the result bundle and a regression is visible rather than folklore.
    ///
    /// Launched hermetically, same as every other test here: this measures
    /// *our* startup, not the network's mood.
    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            _ = XCUIApplication.launchedForUITest()
        }
    }
}
