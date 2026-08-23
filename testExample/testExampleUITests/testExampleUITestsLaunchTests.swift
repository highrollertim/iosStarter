import XCTest

/// Smoke test: the app launches at all, on every UI-appearance configuration
/// the suite runs under, and we keep a screenshot in the result bundle.
///
/// Two independent multipliers apply here, and they are worth telling apart.
/// `runsForEachTargetApplicationUIConfiguration` re-runs each test in light
/// and dark appearance. The test plan's two *configurations* (English and
/// German) re-run the whole suite in each language. So the screenshots in the
/// result bundle cover both appearances in both languages — which is what
/// makes this the app's localization smoke check as well as its launch one.
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
