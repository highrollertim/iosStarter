import XCTest

/// Smoke test: the app launches at all, on every UI-appearance configuration
/// the suite runs under, and we keep a screenshot in the result bundle.
///
/// Two independent multipliers apply here, and they are worth telling apart —
/// the result bundle is confusing until you do.
///
/// `runsForEachTargetApplicationUIConfiguration` makes XCTest derive
/// configurations from the *app*: the run is repeated across combinations of
/// appearance, the app's supported localizations, and orientation. Measured,
/// not assumed — the bundle labels them "Light Appearance, German, Portrait
/// Upside Down" and the like, eight per run here.
///
/// The test plan's two *configurations* are a separate axis, and a stronger
/// one: they relaunch the app under `de`/`DE` for real, which is what makes
/// the German pass a localization check rather than a metadata permutation.
/// So these screenshots span both, and this class is the app's launch smoke
/// test and its most direct German one at the same time.
final class LaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
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
